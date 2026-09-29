import OnboardCore
import SwiftUI

/// Drives the provisioning UI: polls a `ProgressProviding` source and republishes
/// the merged display. Polling (1 s) rather than a push channel keeps the XPC
/// surface to the two calls the daemon already exposes, and means a UI that
/// starts late — or restarts after the session is torn down — is always
/// correct on its first tick.
@MainActor
@Observable
public final class ProvisioningViewModel {
    public private(set) var display: ProvisioningDisplay
    public private(set) var isRetrying = false

    private let source: any ProgressProviding
    private let loadConfiguration: @Sendable () -> Configuration?
    private let deviceInfo: DeviceInfo
    private var configuration: Configuration?
    private var pollTask: Task<Void, Never>?
    private var pollInterval: Duration = .seconds(1)

    public init(
        source: any ProgressProviding,
        loadConfiguration: @escaping @Sendable () -> Configuration? = { try? ConfigLoader.load() },
        deviceInfo: DeviceInfo = .current()
    ) {
        self.source = source
        self.loadConfiguration = loadConfiguration
        self.deviceInfo = deviceInfo
        self.display = ProvisioningDisplay(phase: .connecting)
    }

    /// How many consecutive finished readings end the poll loop.
    ///
    /// Not one. The first reading routinely comes from a *departed* daemon:
    /// `currentSnapshot` is itself what makes launchd re-spawn it, and the
    /// fresh daemon answers from `progress.json` — last run's verdict —
    /// before it has published anything of its own. Stopping on that would
    /// freeze the card on a stale result while a real run went on behind it.
    /// A few seconds of an unchanging verdict is plenty: a new daemon
    /// publishes within milliseconds of starting.
    private static let finishedReadingsBeforeStopping = 5

    /// Polls until the run has plainly settled, then stops.
    ///
    /// Stopping matters more than it looks. The daemon exits a few seconds
    /// after each run and launchd re-spawns it on demand, so every poll to a
    /// departed daemon starts a root process — one every ten seconds, for as
    /// long as the card is up. A settled run will not change on its own, so
    /// polling past it bought nothing and cost a spawn and two log lines per
    /// cycle, indefinitely, on any Mac left showing a failure. Retry
    /// restarts the loop, because that *does* change things.
    public func start(pollInterval: Duration = .seconds(1)) {
        guard pollTask == nil else { return }
        self.pollInterval = pollInterval
        pollTask = Task { [weak self] in
            var finishedReadings = 0
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { break }
                finishedReadings = self.display.phase.isFinished ? finishedReadings + 1 : 0
                if finishedReadings >= Self.finishedReadingsBeforeStopping { break }
                try? await Task.sleep(for: pollInterval)
            }
            self?.clearPollTask()
        }
    }

    /// The loop owns the handle while it runs, so `start` can tell a stopped
    /// loop from a running one and restart it.
    private func clearPollTask() {
        pollTask = nil
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called just before the escape hatch quits the app, so the daemon stops
    /// putting the window back.
    public func prepareForForcedExit() async {
        await source.requestUISuppression()
    }

    public func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        // The daemon exits a few seconds after each run, so the press may be
        // what launchd spawns it for — and a daemon that has not yet reached
        // its verdict refuses. Ask once more a moment later. Safe to repeat:
        // the daemon refuses anything it is not ready for, so this can never
        // start two runs.
        if await source.requestRetry() == false {
            try? await Task.sleep(for: .milliseconds(750))
            _ = await source.requestRetry()
        }
        isRetrying = false
        await refresh()
        // The run is moving again, so the card has something to watch.
        start(pollInterval: pollInterval)
    }

    private func refresh() async {
        // The profile can arrive after the UI does — the daemon waits for it
        // too — so keep trying until it parses.
        if configuration == nil {
            configuration = loadConfiguration()
        }
        let snapshot = await source.currentSnapshot()
        display = .make(configuration: configuration, snapshot: snapshot, deviceInfo: deviceInfo)
    }
}

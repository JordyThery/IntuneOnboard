import OnboardCore
import SwiftUI

/// Polls a `ProgressProviding` source every second and publishes the merged
/// display. Polling means a UI that starts late is correct from its first update.
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

    /// Consecutive finished readings before polling stops. The first
    /// reading can come from `progress.json` before a newly started daemon
    /// has published, so one is not enough.
    private static let finishedReadingsBeforeStopping = 5

    /// Polls until the run has settled, then stops. Each poll can start the
    /// daemon, so polling is not continued indefinitely. Retry restarts it.
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

    /// Held while the loop runs, so `start` can restart a stopped loop.
    private func clearPollTask() {
        pollTask = nil
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called before ⌃⌥⌘Q quits, so the daemon stops relaunching the window.
    public func prepareForForcedExit() async {
        await source.requestUISuppression()
    }

    public func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        // The daemon may just be starting and not yet accept a retry; ask
        // again shortly. It rejects requests it is not ready for, so this
        // cannot start two runs.
        if await source.requestRetry() == false {
            try? await Task.sleep(for: .milliseconds(750))
            _ = await source.requestRetry()
        }
        isRetrying = false
        await refresh()
        // A new run started; resume polling.
        start(pollInterval: pollInterval)
    }

    private func refresh() async {
        // The profile can arrive after the UI starts; retry until it parses.
        if configuration == nil {
            configuration = loadConfiguration()
        }
        let snapshot = await source.currentSnapshot()
        display = .make(configuration: configuration, snapshot: snapshot, deviceInfo: deviceInfo)
    }
}

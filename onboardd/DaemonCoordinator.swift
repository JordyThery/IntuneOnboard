import Foundation
import OnboardCore
import os

/// Owns the daemon's run: wait for config → preflight → engine → marker.
/// Serves snapshots to the XPC layer and accepts retry requests.
actor DaemonCoordinator {
    enum Phase {
        case idle
        case waitingForConfig
        case preflight
        case running
        case finished(ProvisioningEngine.Result)
    }

    private var phase: Phase = .idle
    private var engine: ProvisioningEngine?
    private var configuration: Configuration?
    private var snapshot: ProgressSnapshot?
    private var uiSuppressed = false
    private let store = StateStore()

    /// The sinks are built from the profile's `logging` dictionary, not from
    /// `RotatingFileSink`'s defaults.
    ///
    /// They used to be built with the defaults and the configured values were
    /// simply dropped, so `maxFileSizeMB` and `keepArchives` did nothing at
    /// all — a profile asking for 1 MB let the log reach 3.4 MB unrotated on
    /// hardware. Read here, once, rather than at every write: the config is
    /// fixed for the life of the process, and the sinks have to exist before
    /// the run that would read it.
    private let fileLog: RotatingFileSink
    private let installomatorLog: RotatingFileSink

    init() {
        let logging = (try? ConfigLoader.load())?.logging ?? Configuration.Logging()
        fileLog = RotatingFileSink(
            fileURL: URL(filePath: "/var/log/IntuneOnboard/onboard.log"),
            maxFileSizeMB: logging.maxFileSizeMB,
            keepArchives: logging.keepArchives
        )
        installomatorLog = RotatingFileSink(
            fileURL: URL(filePath: "/var/log/IntuneOnboard/onboard-installomator.log"),
            maxFileSizeMB: logging.maxFileSizeMB,
            keepArchives: logging.keepArchives
        )
    }

    // MARK: - Main run

    /// The full daemon run; returns the process exit code.
    func run() async -> Int32 {
        log("onboardd run starting")

        // A finished device short-circuits before anything else — in
        // particular before publishing "waiting for the configuration
        // profile", which would otherwise make a provisioned Mac claim it was
        // waiting again every time launchd re-spawned us on demand.
        if isDeviceComplete() {
            // Load the config so the snapshot can name the items. Without one
            // we leave progress.json alone rather than replacing it with
            // something emptier than what is already there.
            configuration = try? ConfigLoader.load()
            // DEBUG overrides the short-circuit: a dry run on an
            // already-provisioned bench Mac is exactly what the key is for.
            // The engine starts from a blank in-memory slate and persists
            // nothing, so the real marker survives untouched.
            if configuration?.dryRun != true {
                log("device marker present — nothing to do")
                if configuration != nil {
                    publish(state: .completed)
                }
                return ExitCode.success.rawValue
            }
            log("device marker present but DEBUG is set — dry-running anyway")
        }

        // Settled: every item is terminal and the failed ones are out of
        // automatic attempts, so this spawn could not change anything. Stop
        // here rather than republishing "waiting" and "checking this Mac…"
        // — launchd re-spawns us every ten seconds while a card is polling,
        // and on hardware that reset the card (and wiped its buttons) on
        // every cycle, as well as renaming the Mac over and over.
        //
        // Before the wait and the publishes above, deliberately: the resets
        // are the damage. A verdict still reaches the UI, and `phase` is set
        // so an explicit Try again is accepted.
        if configuration == nil { configuration = try? ConfigLoader.load() }
        if let configuration, configuration.dryRun != true {
            if let settled = settledResult(configuration) {
                log("nothing left to attempt automatically — last result stands; Try again to start over")
                phase = .finished(settled)
                publish(state: .completedWithErrors)
                return settled.exitCode.rawValue
            }
            // The same cap for preflight. It has no item records to judge —
            // nothing ran — so it counts its own failures, and without this
            // an unreachable required endpoint re-ran the network checks
            // roughly six times a minute for as long as a card was up.
            let failures = (try? store.loadDeviceState())?.preflightFailures ?? 0
            if failures >= ProvisioningEngine.maxAutomaticAttempts {
                log("preflight has failed \(failures) times; not retrying automatically — Try again to start over")
                phase = .finished(ProvisioningEngine.Result(markerWritten: false, failedRequiredIDs: []))
                // Re-check rather than remember: the answer is cheap, and an
                // ineligible Mac must keep saying so on every spawn.
                let ineligible = configuration.requireADE
                    ? !(await Preflight().isADEEnrolled())
                    : false
                publish(state: .preflightFailed, ineligible: ineligible)
                return (ineligible ? ExitCode.notADE : .networkPreflightFailed).rawValue
            }
        }

        // 1. Config. The ten minutes are fixed and cannot be configured:
        // this is the wait *for* the configuration, so any key naming its
        // own timeout could only be read after the wait it was meant to
        // govern. Giving up is not final — the daemon declares MachServices,
        // so the next XPC connection (the login agent, or the card polling)
        // brings it back for another attempt.
        phase = .waitingForConfig
        publish(state: .waitingForConfig)
        guard let configuration = await waitForConfiguration() else {
            log("no configuration after wait timeout; giving up")
            // Publish a terminal state, or the UI keeps showing "waiting for
            // the configuration profile" forever — which is what stranded the
            // first M3 hardware run.
            publish(state: .preflightFailed)
            return ExitCode.completedWithErrors.rawValue
        }
        self.configuration = configuration

        // 2. Preflight.
        phase = .preflight
        publish(state: .preflight)
        do {
            try await Preflight().run(configuration: configuration)
            recordPreflightOutcome(failed: false)
        } catch let error as PreflightError {
            log("preflight failed: \(error.description)")
            recordPreflightOutcome(failed: true)
            // `notADE` says this Mac may not be configured at all, so the
            // user session has to know: an unreachable endpoint still leaves
            // onboarding worth doing, an ineligible Mac does not.
            publish(state: .preflightFailed, ineligible: error == .notADE)
            return error.exitCode.rawValue
        } catch {
            log("preflight failed: \(error.localizedDescription)")
            recordPreflightOutcome(failed: true)
            publish(state: .preflightFailed)
            return ExitCode.completedWithErrors.rawValue
        }

        // 3. Name the Mac, when configured — before the items, so scripts
        // that read the name see the new one. Failure is loud but not fatal:
        // a Mac that provisions under its old name beats one that stops.
        await applyComputerName(configuration: configuration)

        // 4. Engine, kept awake.
        let assertion = PowerAssertion()
        defer { assertion.release() }
        let result = await runEngine(configuration: configuration)
        phase = .finished(result)

        if result.dryRun {
            log("DEBUG dry run finished — nothing executed, device marker NOT written; remove the DEBUG key to provision for real")
        } else {
            log(result.markerWritten
                ? "provisioning complete, device marker written"
                : "provisioning finished with failures: \(result.failedRequiredIDs.joined(separator: ", "))")
        }
        return result.exitCode.rawValue
    }

    private func applyComputerName(configuration: Configuration) async {
        guard let template = configuration.provisioning?.deviceNameTemplate else { return }
        switch await DeviceNamer().apply(template: template, dryRun: configuration.dryRun) {
        case .named(let computerName, let localHostName):
            log("computer named \"\(computerName)\" (LocalHostName \(localHostName)) from template \(template.raw)")
        case .dryRun(let computerName):
            log("DEBUG — would name this Mac \"\(computerName)\" from template \(template.raw); not applied")
        case .valueUnavailable:
            log("deviceNameTemplate \(template.raw): a token has no value on this device — name left unchanged")
        case .failed(let message):
            log("deviceNameTemplate failed: \(message)")
        }
    }

    private func runEngine(
        configuration: Configuration,
        clearAttemptCounts: Bool = false
    ) async -> ProvisioningEngine.Result {
        phase = .running
        let appBundle = SetupAssistantLauncher.appBundleURL()
        let installomatorSink = installomatorLog
        let runSink = fileLog
        var context = ActionContext()
        context.logSink = { line in runSink.write(line) }
        context.installomatorPath = appBundle
            .appending(path: "Contents/Resources/Installomator/Installomator.sh").path
        context.installomatorDefaultOptions = configuration.installomator.defaultOptions
        context.installomatorLogSink = { line in installomatorSink.write(line) }

        let engine = ProvisioningEngine(
            configuration: configuration,
            store: store,
            context: context,
            clearAttemptCounts: clearAttemptCounts,
            onProgress: { [weak self] snapshot in
                Task { await self?.updateSnapshot(snapshot) }
            }
        )
        self.engine = engine
        return await engine.run()
    }

    /// How long one attempt waits for the profile. See `run()` for why
    /// this is a constant rather than a setting.
    private static let configWaitSeconds = 600

    private func waitForConfiguration() async -> Configuration? {
        let deadline = ContinuousClock.now + .seconds(Self.configWaitSeconds)
        while ContinuousClock.now < deadline {
            do {
                return try ConfigLoader.load()
            } catch let error as ConfigLoadError {
                switch error {
                case .fileNotFound:
                    break // keep polling silently
                case .invalid(let errors):
                    log("configuration invalid (\(errors.count) error(s)); still polling for a fixed profile")
                default:
                    log("configuration unreadable: \(error.description)")
                }
            } catch {
                log("configuration load error: \(error.localizedDescription)")
            }
            try? await Task.sleep(for: .seconds(5))
        }
        return nil
    }

    // MARK: - XPC surface

    private func isDeviceComplete() -> Bool {
        (try? store.loadDeviceState())?.completedAt != nil
    }

    /// Counts consecutive preflight failures, and clears the count the
    /// moment preflight passes — a network that came back should leave no
    /// trace of having been away.
    private func recordPreflightOutcome(failed: Bool) {
        var state = (try? store.loadDeviceState()) ?? DeviceState()
        let updated = failed ? state.preflightFailures + 1 : 0
        guard updated != state.preflightFailures else { return }
        state.preflightFailures = updated
        try? store.saveDeviceState(state)
    }

    /// The verdict a previous run already reached, when no further automatic
    /// attempt could change it. Nil while there is still work to do.
    private func settledResult(_ configuration: Configuration) -> ProvisioningEngine.Result? {
        let items = configuration.provisioning?.items ?? []
        guard !items.isEmpty, let records = (try? store.loadDeviceState())?.items else { return nil }
        guard !ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: records) else {
            return nil
        }
        let failed = items.filter(\.required).map(\.id).filter { records[$0]?.outcome == .failed }
        return ProvisioningEngine.Result(markerWritten: false, failedRequiredIDs: failed)
    }

    /// False once the run has reached a verdict, or once an administrator has
    /// dismissed the UI on purpose. The session monitor uses this to decide
    /// whether to put the window back.
    func isRunActive() -> Bool {
        guard !uiSuppressed else { return false }
        // A marker-present instance returns from run() before `phase` ever
        // leaves `.idle`, so the phase alone would report this daemon as
        // active and the session monitor would keep putting the kiosk back on
        // an already-provisioned Mac.
        guard !isDeviceComplete() else { return false }
        if case .finished = phase { return false }
        return true
    }

    /// The ⌃⌥⌘Q escape hatch, arriving over XPC. Provisioning continues; only
    /// the window stays away.
    func suppressUIRelaunch() {
        guard !uiSuppressed else { return }
        uiSuppressed = true
        log("UI relaunch suppressed by the administrator escape hatch; provisioning continues")
    }

    func latestSnapshot() -> ProgressSnapshot? {
        if let snapshot { return snapshot }
        return ProgressSnapshot.read(from: store.progressFileURL)
    }

    /// Re-runs the engine when the last pass left failed required items.
    func requestRetry() async -> Bool {
        guard case .finished(let result) = phase, !result.markerWritten,
              let configuration else { return false }
        log("retry requested over XPC")
        // Asked for, so both caps start over: someone who presses Try again
        // has usually just fixed what was wrong. The preflight count goes
        // too — the most likely thing they fixed is the network.
        recordPreflightOutcome(failed: false)
        let result2 = await runEngine(configuration: configuration, clearAttemptCounts: true)
        phase = .finished(result2)
        return true
    }

    // MARK: - Internals

    private func updateSnapshot(_ new: ProgressSnapshot) {
        snapshot = new
    }

    /// Publishes a phase change, carrying whatever the store already knows
    /// about each item.
    ///
    /// This used to hardcode `.pending`. Because launchd re-spawns the daemon
    /// on demand (MachServices) whenever the UI polls, a finished device got a
    /// fresh daemon that saw the marker, published `.completed` — and wiped
    /// progress.json back to an empty slate. The UI then said "Your Mac is
    /// ready" above "0 of 4 complete".
    private func publish(state: ProgressSnapshot.EngineState, ineligible: Bool = false) {
        let deviceState = try? store.loadDeviceState()
        let snapshot = ProgressSnapshot.make(
            engineState: state,
            itemIDs: (configuration?.provisioning?.items ?? []).map(\.id),
            records: deviceState?.items ?? [:],
            startedAt: deviceState?.lastRunAt,
            ineligible: ineligible
        )
        self.snapshot = snapshot
        snapshot.write(to: store.progressFileURL)
    }

    private func log(_ message: String) {
        OnboardLog.daemon.notice("\(message, privacy: .public)")
        fileLog.write(message)
    }
}

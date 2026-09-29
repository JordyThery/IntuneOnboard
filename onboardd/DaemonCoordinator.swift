import Foundation
import OnboardCore
import os

/// Runs provisioning: wait for configuration, preflight, engine, marker.
/// Serves progress to the XPC service and accepts retry requests.
actor DaemonCoordinator {
    enum Phase {
        case idle
        case waitingForConfig
        case preflight
        case running
        case finished(ProvisioningEngine.Result)
    }

    private var phase: Phase = .idle
    private var configuration: Configuration?
    private var snapshot: ProgressSnapshot?
    private var uiSuppressed = false
    private let store = StateStore()

    /// Built at init so logging works immediately, and rebuilt once the
    /// profile arrives if its `logging` settings differ.
    private var fileLog: RotatingFileSink
    private var installomatorLog: RotatingFileSink
    private var sinkSettings: (maxFileSizeMB: Int, keepArchives: Int)

    init() {
        let logging = (try? ConfigLoader.load())?.logging ?? Configuration.Logging()
        sinkSettings = (logging.maxFileSizeMB, logging.keepArchives)
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

    private func rebuildSinks(logging: Configuration.Logging) {
        guard (logging.maxFileSizeMB, logging.keepArchives) != sinkSettings else { return }
        sinkSettings = (logging.maxFileSizeMB, logging.keepArchives)
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

    /// Keeps the process alive while a retry started over XPC is running.
    private let exitGate = ExitGate(initialExitCode: ExitCode.success.rawValue)

    /// Runs provisioning; returns the exit code.
    func run() async -> Int32 {
        let exitCode = await performRun()
        await exitGate.record(exitCode: exitCode)
        return exitCode
    }

    /// The exit code, once no retry is in progress.
    func settledExitCode() async -> Int32 {
        await exitGate.settledExitCode()
    }

    private func performRun() async -> Int32 {
        log("onboardd run starting")

        // A completed Mac stops here, before publishing "waiting", because
        // launchd starts the daemon again on every XPC connection.
        if isDeviceComplete() {
            configuration = try? ConfigLoader.load()
            // A dry run still runs on a completed Mac; it persists nothing.
            if configuration?.dryRun != true {
                log("device marker present — nothing to do")
                if configuration != nil {
                    publish(state: .completed)
                }
                return ExitCode.success.rawValue
            }
            log("device marker present but dryRun is set — dry-running anyway")
        }

        // Nothing left to retry automatically: report the last result without
        // re-running preflight or device naming.
        if configuration == nil { configuration = try? ConfigLoader.load() }
        if let configuration, configuration.dryRun != true {
            if let settled = settledResult(configuration) {
                log("nothing left to attempt automatically — last result stands; Try again to start over")
                phase = .finished(settled)
                publish(state: .completedWithErrors)
                return settled.exitCode.rawValue
            }
            let failures = (try? store.loadDeviceState())?.preflightFailures ?? 0
            if failures >= ProvisioningEngine.maxAutomaticAttempts {
                log("preflight has failed \(failures) times; not retrying automatically — Try again to start over")
                phase = .finished(ProvisioningEngine.Result(markerWritten: false, failedRequiredIDs: []))
                let ineligible = configuration.requireADE
                    ? !(await Preflight().isADEEnrolled())
                    : false
                publish(state: .preflightFailed, ineligible: ineligible)
                return (ineligible ? ExitCode.notADE : .networkPreflightFailed).rawValue
            }
        }

        // 1. Configuration. The next XPC connection starts another attempt
        // after a timeout.
        phase = .waitingForConfig
        publish(state: .waitingForConfig)
        guard let configuration = await waitForConfiguration() else {
            log("no configuration after wait timeout; giving up")
            // Terminal state, so the UI stops showing "waiting".
            publish(state: .preflightFailed)
            return ExitCode.completedWithErrors.rawValue
        }
        self.configuration = configuration
        rebuildSinks(logging: configuration.logging)

        // 2. Preflight.
        phase = .preflight
        publish(state: .preflight)
        do {
            try await Preflight().run(configuration: configuration)
            recordPreflightOutcome(failed: false)
        } catch let error as PreflightError {
            log("preflight failed: \(error.description)")
            recordPreflightOutcome(failed: true)
            // An ineligible Mac must also skip onboarding.
            publish(state: .preflightFailed, ineligible: error == .notADE)
            return error.exitCode.rawValue
        } catch {
            log("preflight failed: \(error.localizedDescription)")
            recordPreflightOutcome(failed: true)
            publish(state: .preflightFailed)
            return ExitCode.completedWithErrors.rawValue
        }

        // 3. Device name, before the items so scripts see it. Not fatal.
        await applyComputerName(configuration: configuration)

        // 4. Items, with sleep prevented.
        let assertion = PowerAssertion()
        defer { assertion.release() }
        let result = await runEngine(configuration: configuration)
        phase = .finished(result)

        if result.dryRun {
            log("dry run finished — nothing executed, device marker not written; remove dryRun to provision for real")
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
            log("dry run — would name this Mac \"\(computerName)\" from template \(template.raw); not applied")
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
        return await engine.run()
    }

    /// Not configurable: it bounds the wait for the configuration itself.
    private static let configWaitSeconds = 600

    private func waitForConfiguration() async -> Configuration? {
        let deadline = ContinuousClock.now + .seconds(Self.configWaitSeconds)
        while ContinuousClock.now < deadline {
            do {
                return try ConfigLoader.load()
            } catch let error as ConfigLoadError {
                switch error {
                case .fileNotFound:
                    break
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

    /// Counts consecutive preflight failures; a pass resets the count.
    private func recordPreflightOutcome(failed: Bool) {
        var state = (try? store.loadDeviceState()) ?? DeviceState()
        let updated = failed ? state.preflightFailures + 1 : 0
        guard updated != state.preflightFailures else { return }
        state.preflightFailures = updated
        try? store.saveDeviceState(state)
    }

    /// The previous result, when no automatic attempt remains; nil otherwise.
    private func settledResult(_ configuration: Configuration) -> ProvisioningEngine.Result? {
        let items = configuration.provisioning?.items ?? []
        guard !items.isEmpty, let records = (try? store.loadDeviceState())?.items else { return nil }
        guard !ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: records) else {
            return nil
        }
        let failed = items.filter(\.required).map(\.id).filter { records[$0]?.outcome == .failed }
        return ProvisioningEngine.Result(markerWritten: false, failedRequiredIDs: failed)
    }

    /// Whether the session monitor should keep the window up.
    func isRunActive() -> Bool {
        guard !uiSuppressed else { return false }
        // Checked separately: a completed Mac returns before `phase` changes.
        guard !isDeviceComplete() else { return false }
        if case .finished = phase { return false }
        return true
    }

    /// ⌃⌥⌘Q: stop relaunching the window. Provisioning continues.
    func suppressUIRelaunch() {
        guard !uiSuppressed else { return }
        uiSuppressed = true
        log("UI relaunch suppressed by the administrator escape hatch; provisioning continues")
    }

    func latestSnapshot() -> ProgressSnapshot? {
        if let snapshot { return snapshot }
        return ProgressSnapshot.read(from: store.progressFileURL)
    }

    /// Runs failed and unfinished items again, resetting both attempt limits.
    func requestRetry() async -> Bool {
        guard case .finished(let result) = phase, !result.markerWritten,
              let configuration else { return false }
        log("retry requested over XPC")
        recordPreflightOutcome(failed: false)
        await exitGate.beginWork()
        let result2 = await runEngine(configuration: configuration, clearAttemptCounts: true)
        phase = .finished(result2)
        await exitGate.endWork(exitCode: result2.exitCode.rawValue)
        return true
    }

    // MARK: - Internals

    private func updateSnapshot(_ new: ProgressSnapshot) {
        snapshot = new
    }

    /// Publishes a state change with the item records already on disk.
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

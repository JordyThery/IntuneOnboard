import Foundation

/// Everything an action needs to execute, injectable for tests.
public struct ActionContext: Sendable {
    public var processRunner: any ProcessRunning
    /// Path to the vendored Installomator.sh inside the app bundle.
    public var installomatorPath: String
    public var installomatorDefaultOptions: [String]
    /// Receives raw Installomator output for the dedicated log file.
    public var installomatorLogSink: (@Sendable (String) -> Void)?
    /// Receives the run's own narration — item transitions and script output —
    /// for `onboard.log`, which is the only log readable during Setup
    /// Assistant (⌘L, first tab). Without it the engine's story lived in the
    /// unified log alone, where nobody at that point in setup can reach it.
    public var logSink: (@Sendable (String) -> Void)?
    /// Live status-text updates ("status:" script lines).
    public var statusTextHandler: (@Sendable (String) -> Void)?
    public var fileExists: @Sendable (String) -> Bool
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        processRunner: any ProcessRunning = LiveProcessRunner(),
        installomatorPath: String = "",
        installomatorDefaultOptions: [String] = InstallomatorOptions.bootstrapDefaults,
        installomatorLogSink: (@Sendable (String) -> Void)? = nil,
        logSink: (@Sendable (String) -> Void)? = nil,
        statusTextHandler: (@Sendable (String) -> Void)? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.processRunner = processRunner
        self.installomatorPath = installomatorPath
        self.installomatorDefaultOptions = installomatorDefaultOptions
        self.installomatorLogSink = installomatorLogSink
        self.logSink = logSink
        self.statusTextHandler = statusTextHandler
        self.fileExists = fileExists
        self.sleep = sleep
    }
}

/// What an action reports back to the engine.
public struct ActionResult: Sendable, Equatable {
    public let outcome: ItemOutcome
    public let status: StatusKind
    public let message: String?

    public init(outcome: ItemOutcome, status: StatusKind, message: String? = nil) {
        self.outcome = outcome
        self.status = status
        self.message = message
    }

    public static let success = ActionResult(outcome: .success, status: .done)
}

public enum ProvisioningActionRunner {
    /// Executes one provisioning item and applies validatePath semantics.
    public static func execute(_ item: ProvisioningItem, context: ActionContext) async -> ActionResult {
        let raw: ActionResult
        switch item.kind {
        case .installomator(let label, let options):
            raw = await InstallomatorAction.run(item: item, label: label, options: options, context: context)
        case .script(let spec):
            raw = await ScriptAction.run(item: item, spec: spec, context: context)
        case .wait(let seconds, _):
            raw = await WaitAction.run(seconds: seconds, timeout: item.timeout, context: context)
        case .awaitPath(let path, let condition):
            raw = await WaitForPathAction.run(path: path, condition: condition, timeout: item.timeout, context: context)
        }

        // validatePath applies after any successful run, whatever the kind.
        if raw.outcome == .success, let expected = item.validatePath, !context.fileExists(expected) {
            return ActionResult(
                outcome: .failed,
                status: .failed,
                message: "validatePath missing after success: \(expected)"
            )
        }
        return raw
    }
}

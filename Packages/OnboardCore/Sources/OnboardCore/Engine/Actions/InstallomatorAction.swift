import Foundation

/// Runs one Installomator label. `DEBUG=0` is always the last argument.
enum InstallomatorAction {
    static func run(
        item: ProvisioningItem,
        label: String,
        options: [String],
        context: ActionContext
    ) async -> ActionResult {
        guard context.fileExists(context.installomatorPath) else {
            return ActionResult(
                outcome: .failed,
                status: .failed,
                message: "Installomator missing at \(context.installomatorPath)"
            )
        }

        let arguments = [context.installomatorPath, label] + InstallomatorOptions.effectiveArguments(
            defaults: context.installomatorDefaultOptions,
            itemOptions: options
        )

        let result: ProcessResult
        do {
            result = try await context.processRunner.run(
                executable: "/bin/zsh",
                arguments: arguments,
                environment: minimalEnvironment,
                timeout: .seconds(item.timeout),
                lineHandler: { line in
                    context.installomatorLogSink?(line)
                }
            )
        } catch {
            return ActionResult(outcome: .failed, status: .failed, message: error.localizedDescription)
        }

        if result.timedOut {
            return ActionResult(outcome: .failed, status: .timedOut, message: "timed out after \(item.timeout)s")
        }
        guard result.exitCode == 0 else {
            return ActionResult(
                outcome: .failed,
                status: .failed,
                message: "Installomator exit \(result.exitCode) for label \(label)"
            )
        }
        return ActionResult(outcome: .success, status: .installed)
    }

    static let minimalEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/var/root",
    ]
}

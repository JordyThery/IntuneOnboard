import Foundation

/// Runs an admin-supplied root script with a minimal environment.
/// Inline scripts are written to a fresh 0700 root-only directory and the
/// directory is removed afterwards. Path scripts are re-checked for safe
/// ownership at run time (validation already checked at config load).
enum ScriptAction {
    static func run(
        item: ProvisioningItem,
        spec: ProvisioningItem.ScriptSpec,
        context: ActionContext
    ) async -> ActionResult {
        let scriptPath: String
        var temporaryDirectory: URL?

        switch spec.source {
        case .inline(let body):
            do {
                let directory = URL(filePath: NSTemporaryDirectory())
                    .appending(path: "onboard-script-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let file = directory.appending(path: "script")
                try Data(body.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                scriptPath = file.path
                temporaryDirectory = directory
            } catch {
                return ActionResult(outcome: .failed, status: .failed, message: "could not stage inline script: \(error.localizedDescription)")
            }
        case .path(let path):
            if let reason = insecurePathReason(path) {
                return ActionResult(outcome: .failed, status: .failed, message: "script path rejected: \(reason)")
            }
            scriptPath = path
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let result: ProcessResult
        do {
            result = try await context.processRunner.run(
                executable: spec.interpreter,
                arguments: [scriptPath] + spec.arguments,
                environment: InstallomatorAction.minimalEnvironment,
                timeout: .seconds(item.timeout),
                lineHandler: { line in
                    // Every line goes to the log: a script is admin-supplied
                    // code running as root, and its output is the only
                    // account of what it did.
                    context.logSink?("[\(item.id)] \(line)")
                    // Lines like "status: Doing the thing" update the row.
                    if spec.statusFromOutput, let text = statusText(from: line) {
                        context.statusTextHandler?(text)
                    }
                }
            )
        } catch {
            return ActionResult(outcome: .failed, status: .failed, message: error.localizedDescription)
        }

        // stderr is collected rather than streamed, so it arrives here in one
        // piece. It is where a failing script says why, so it goes to the log
        // whatever the exit code.
        for line in result.standardError.split(separator: "\n") {
            context.logSink?("[\(item.id)] stderr: \(line)")
        }

        if result.timedOut {
            return ActionResult(outcome: .failed, status: .timedOut, message: "timed out after \(item.timeout)s")
        }
        guard spec.successExitCodes.contains(Int(result.exitCode)) else {
            let stderrTail = result.standardError.split(separator: "\n").suffix(3).joined(separator: " | ")
            return ActionResult(
                outcome: .failed,
                status: .failed,
                message: "exit \(result.exitCode)\(stderrTail.isEmpty ? "" : " — \(stderrTail)")"
            )
        }
        return ActionResult(outcome: .success, status: .done)
    }

    static func statusText(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("status:") else { return nil }
        return String(trimmed.dropFirst("status:".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Runtime re-check of the config-time rule: root-owned, not writable by
    /// group/others. Nil when acceptable.
    static func insecurePathReason(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "file does not exist"
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if owner != 0 { return "not owned by root" }
        if permissions & 0o022 != 0 { return "group/world-writable" }
        return nil
    }
}

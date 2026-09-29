import Foundation

/// Runs a configured script as root with a minimal environment.
///
/// The script body is staged in a new root-only directory and run from there.
/// For `path` scripts the body is read through the verified file descriptor,
/// so the file cannot be replaced between the check and execution. `$0` is
/// therefore the staged copy's path.
enum ScriptAction {
    static func run(
        item: ProvisioningItem,
        spec: ProvisioningItem.ScriptSpec,
        context: ActionContext
    ) async -> ActionResult {
        let body: Data
        switch spec.source {
        case .inline(let text):
            body = Data(text.utf8)
        case .path(let path):
            switch verifiedContent(of: path) {
            case .failure(let reason):
                return ActionResult(outcome: .failed, status: .failed, message: "script path rejected: \(reason)")
            case .success(let data):
                body = data
            }
        }

        let scriptPath: String
        let temporaryDirectory: URL
        do {
            (scriptPath, temporaryDirectory) = try stage(body)
        } catch {
            return ActionResult(outcome: .failed, status: .failed, message: "could not stage script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let result: ProcessResult
        do {
            result = try await context.processRunner.run(
                executable: spec.interpreter,
                arguments: [scriptPath] + spec.arguments,
                environment: InstallomatorAction.minimalEnvironment,
                timeout: .seconds(item.timeout),
                lineHandler: { line in
                    // All output is logged; it is the only record of what
                    // the script did.
                    context.logSink?("[\(item.id)] \(line)")
                    // "status: …" lines update the item's status text.
                    if spec.statusFromOutput, let text = statusText(from: line) {
                        context.statusTextHandler?(text)
                    }
                }
            )
        } catch {
            return ActionResult(outcome: .failed, status: .failed, message: error.localizedDescription)
        }

        // Logged whatever the exit code.
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

    /// Writes the body to a new 0700 directory; the caller removes it.
    private static func stage(_ body: Data) throws -> (path: String, directory: URL) {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "onboard-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appending(path: "script")
        try body.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return (file.path, directory)
    }

    enum ContentOutcome: Equatable {
        case success(Data)
        case failure(String)
    }

    /// Opens `path` without following a final symlink, checks through the
    /// descriptor that it is a regular file owned by `requiredOwner` and not
    /// writable by group or others, and returns its contents.
    ///
    /// `requiredOwner` is overridable for tests.
    static func verifiedContent(of path: String, requiredOwner: uid_t = 0) -> ContentOutcome {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let reason = errno == ELOOP ? "symbolic links are not allowed" : "file does not exist"
            return .failure(reason)
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return .failure("could not stat the file")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .failure("not a regular file")
        }
        guard info.st_uid == requiredOwner else {
            return .failure("not owned by root")
        }
        guard info.st_mode & 0o022 == 0 else {
            return .failure("group/world-writable")
        }

        do {
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
            guard !data.isEmpty else { return .failure("the file is empty") }
            return .success(data)
        } catch {
            return .failure("could not read the file: \(error.localizedDescription)")
        }
    }
}

import Foundation

/// Runs an admin-supplied root script with a minimal environment.
///
/// Inline scripts are written to a fresh 0700 root-only directory and the
/// directory is removed afterwards. Path scripts go through the same staging,
/// fed by `verifiedContent`: the file is opened once, verified through the
/// *descriptor* (root-owned, not group/world-writable, a regular file, no
/// symlink), and the bytes that passed the check are what gets staged and
/// run. Checking a path and then executing by path left a window in which
/// the file could be swapped; nothing can swap bytes already read.
/// (Executing `/dev/fd/N` directly would be equivalent, but Process spawns
/// children with all non-standard descriptors closed.)
///
/// Consequence worth knowing: `$0` is the staged copy's path, not the
/// configured one — a script must not derive sibling paths from its own
/// location. Config-load validation still checks the same ownership rules by
/// path, where the friendlier error belongs.
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

        // stderr is where a failing script says why, so it goes to the log
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

    /// Writes the script body into a fresh 0700 directory the caller removes.
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

    /// Opens the script and verifies the *descriptor*: owned by
    /// `requiredOwner`, not writable by group or others, a regular file, and
    /// not reached through a symlink at the final component (the old
    /// path-based check examined a symlink's own attributes and could pass a
    /// root-owned link to a file nobody had vetted). The returned bytes are
    /// read from that same descriptor, so what was verified is what runs.
    ///
    /// `requiredOwner` exists for tests, which cannot mint root-owned files;
    /// production callers use the default.
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

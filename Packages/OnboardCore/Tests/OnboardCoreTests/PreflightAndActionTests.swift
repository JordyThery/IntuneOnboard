import Foundation
import Testing
@testable import OnboardCore

@Suite struct PreflightTests {
    @Test func rootRequired() async {
        let preflight = Preflight(uid: { 501 }, probe: { _, _ in true })
        await #expect(throws: PreflightError.notRoot) {
            try await preflight.run(configuration: Configuration())
        }
    }

    @Test func adeParsing() async {
        let enrolled = FakeProcessRunner(results: [ProcessResult(
            exitCode: 0,
            standardOutput: "Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\n",
            standardError: "", timedOut: false
        )])
        let preflight = Preflight(uid: { 0 }, processRunner: enrolled, probe: { _, _ in true })
        let config = Configuration(requireADE: true)
        // Should not throw.
        try? await preflight.run(configuration: config)
        #expect(await preflight.isADEEnrolled())

        let notEnrolled = FakeProcessRunner(results: [ProcessResult(
            exitCode: 0,
            standardOutput: "Enrolled via DEP: No\nMDM enrollment: Yes\n",
            standardError: "", timedOut: false
        )])
        let preflight2 = Preflight(uid: { 0 }, processRunner: notEnrolled, probe: { _, _ in true })
        await #expect(throws: PreflightError.notADE) {
            try await preflight2.run(configuration: config)
        }
    }

    @Test func requiredURLGateAndWarnURLPass() async throws {
        let config = Configuration(network: .init(
            requiredURLs: [URL(string: "https://required.example.com")!],
            warnURLs: [URL(string: "https://warn.example.com")!]
        ))

        let allDown = Preflight(uid: { 0 }, probe: { _, _ in false })
        await #expect(throws: PreflightError.requiredEndpointsUnreachable(["https://required.example.com"])) {
            try await allDown.run(configuration: config)
        }

        // Warn URL down, required up → no throw.
        let warnDown = Preflight(uid: { 0 }, probe: { url, _ in !url.absoluteString.contains("warn") })
        try await warnDown.run(configuration: config)
    }
}

@Suite struct ScriptActionTests {
    /// Real subprocess integration: inline script through /bin/zsh with
    /// status: lines and a non-zero exit accepted via successExitCodes.
    @Test func inlineScriptRunsAndEmitsStatus() async throws {
        let collected = StatusCollector()
        let context = ActionContext(
            processRunner: LiveProcessRunner(),
            statusTextHandler: { collected.append($0) },
            sleep: { _ in }
        )
        let spec = ProvisioningItem.ScriptSpec(
            source: .inline("echo 'status: halfway there'\necho plain\nexit 4"),
            successExitCodes: [0, 4]
        )
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 30)
        let result = await ScriptAction.run(item: item, spec: spec, context: context)

        #expect(result.outcome == .success)
        #expect(collected.lines() == ["halfway there"])
    }

    @Test func failingExitCodeCarriesStderr() async {
        let context = ActionContext(processRunner: LiveProcessRunner(), sleep: { _ in })
        let spec = ProvisioningItem.ScriptSpec(source: .inline("echo oops >&2\nexit 1"))
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 30)
        let result = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message?.contains("oops") == true)
    }

    /// A root script's output is the only account of what it did, and the
    /// ⌘L panel reads `onboard.log` — not the unified log. Both streams have
    /// to reach the sink, tagged with the item, or a script that misbehaves
    /// during Setup Assistant leaves no trace anyone on the Mac can read.
    @Test func scriptOutputReachesTheRunLog() async {
        let collected = StatusCollector()
        let context = ActionContext(
            processRunner: LiveProcessRunner(),
            logSink: { collected.append($0) },
            sleep: { _ in }
        )
        let spec = ProvisioningItem.ScriptSpec(source: .inline("echo hello\necho trouble >&2\nexit 0"))
        let item = ProvisioningItem(id: "rosetta", kind: .script(spec), timeout: 30)
        _ = await ScriptAction.run(item: item, spec: spec, context: context)

        let lines = collected.lines()
        #expect(lines.contains("[rosetta] hello"))
        #expect(lines.contains("[rosetta] stderr: trouble"))
    }

    @Test func timeoutTerminatesProcess() async {
        let context = ActionContext(processRunner: LiveProcessRunner(), sleep: { _ in })
        let spec = ProvisioningItem.ScriptSpec(source: .inline("sleep 60"))
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 1)
        let started = ContinuousClock.now
        let result = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(result.status == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func userOwnedScriptPathRejectedAtRuntime() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "evil-\(UUID().uuidString).sh")
        FileManager.default.createFile(atPath: file.path, contents: Data("exit 0".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let context = ActionContext(processRunner: LiveProcessRunner(), sleep: { _ in })
        let spec = ProvisioningItem.ScriptSpec(source: .path(file.path))
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 30)
        let result = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message?.contains("not owned by root") == true)
    }

    @Test func symlinkedScriptPathRejectedAtRuntime() async {
        let directory = FileManager.default.temporaryDirectory
        let target = directory.appending(path: "target-\(UUID().uuidString).sh")
        let link = directory.appending(path: "link-\(UUID().uuidString).sh")
        FileManager.default.createFile(atPath: target.path, contents: Data("exit 0".utf8))
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        let context = ActionContext(processRunner: LiveProcessRunner(), sleep: { _ in })
        let spec = ProvisioningItem.ScriptSpec(source: .path(link.path))
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 30)
        let result = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message?.contains("symbolic links") == true)
    }

    /// The check-then-execute fix reads the script through the descriptor
    /// that was verified, so what was checked is what runs. `requiredOwner`
    /// lets the test exercise the pipeline without a root-owned fixture; the
    /// mode and symlink rules are the production ones.
    @Test func verifiedContentReadsWhatItChecked() throws {
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appending(path: "vc-\(UUID().uuidString).sh")
        FileManager.default.createFile(
            atPath: file.path,
            contents: Data("echo hello".utf8),
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(ScriptAction.verifiedContent(of: file.path, requiredOwner: getuid())
                == .success(Data("echo hello".utf8)))
        // Wrong owner (root won't own a file this test just made).
        if case .failure(let reason) = ScriptAction.verifiedContent(of: file.path) {
            #expect(reason == "not owned by root")
        } else {
            Issue.record("a user-owned file must not verify against the root requirement")
        }
        // Group-writable is refused even for the right owner.
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: file.path)
        #expect(ScriptAction.verifiedContent(of: file.path, requiredOwner: getuid())
                == .failure("group/world-writable"))
    }

    /// stderr used to be read only after exit, so a child writing more than
    /// the pipe's ~64 KB buffer blocked on write, could never exit, and was
    /// reported as a timeout. `set -x` alone produces that much.
    @Test func chattyStderrScriptStillSucceeds() async {
        let context = ActionContext(processRunner: LiveProcessRunner(), sleep: { _ in })
        // ~200 KB to stderr, then a clean exit.
        let spec = ProvisioningItem.ScriptSpec(source: .inline("""
        for i in {1..2000}; do
            printf '%0100d\\n' "$i" >&2
        done
        exit 0
        """))
        let item = ProvisioningItem(id: "chatty", kind: .script(spec), timeout: 30)
        let result = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(result.outcome == .success, "\(result.message ?? "")")
    }

    /// A final `status:` line without a trailing newline still reaches the
    /// handler — flushed at stdout EOF.
    @Test func unterminatedFinalStatusLineIsFlushed() async {
        let collected = StatusCollector()
        let context = ActionContext(
            processRunner: LiveProcessRunner(),
            statusTextHandler: { collected.append($0) },
            sleep: { _ in }
        )
        let spec = ProvisioningItem.ScriptSpec(source: .inline("printf 'status: almost'"))
        let item = ProvisioningItem(id: "s", kind: .script(spec), timeout: 30)
        _ = await ScriptAction.run(item: item, spec: spec, context: context)
        #expect(collected.lines() == ["almost"])
    }

    /// A timeout must take the process *tree*, not just the interpreter:
    /// killing only zsh left its children — a hung curl, an installer —
    /// running as root after the item was recorded failed.
    @Test func timeoutKillsTheWholeProcessTree() async throws {
        let result = try await LiveProcessRunner().run(
            executable: "/bin/zsh",
            arguments: ["-c", "sleep 60 &\necho \"child:$!\"\nsleep 60"],
            environment: nil,
            timeout: .seconds(1),
            lineHandler: nil
        )
        #expect(result.timedOut)

        let line = try #require(result.standardOutput
            .split(separator: "\n")
            .first { $0.hasPrefix("child:") })
        let childPID = try #require(pid_t(line.dropFirst("child:".count)))

        // SIGTERM delivery is asynchronous; give it a moment.
        var alive = true
        for _ in 0..<20 where alive {
            alive = kill(childPID, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive, "the backgrounded child (pid \(childPID)) must not survive the timeout")
    }

    @Test func statusLineParsing() {
        #expect(ScriptAction.statusText(from: "status: Installing fonts") == "Installing fonts")
        #expect(ScriptAction.statusText(from: "  STATUS:  trimmed  ") == "trimmed")
        #expect(ScriptAction.statusText(from: "no prefix here") == nil)
    }
}

@Suite struct WaitForPathActionTests {
    @Test func succeedsWhenPathAppears() async {
        let flag = Flag()
        let context = ActionContext(
            fileExists: { _ in flag.isSet() },
            sleep: { _ in flag.set() } // path "appears" after the first poll
        )
        let result = await WaitForPathAction.run(path: "/x", condition: .exists, timeout: 10, context: context)
        #expect(result.outcome == .success)
    }

    @Test func absentConditionAndTimeout() async {
        let context = ActionContext(fileExists: { _ in true }, sleep: { _ in })
        let result = await WaitForPathAction.run(path: "/x", condition: .absent, timeout: 0, context: context)
        #expect(result.outcome == .failed)
        #expect(result.status == .timedOut)
    }
}

// MARK: - Test helpers

final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func append(_ line: String) {
        lock.lock(); collected.append(line); lock.unlock()
    }
    func lines() -> [String] {
        lock.lock(); defer { lock.unlock() }; return collected
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

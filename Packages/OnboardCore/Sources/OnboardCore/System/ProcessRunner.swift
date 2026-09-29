import Foundation

/// Result of a completed (or timed-out) subprocess.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool

    public init(exitCode: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

/// Abstraction over Process so actions are unit-testable with fakes.
/// Always argument arrays — never shell strings (spec §0).
public protocol ProcessRunning: Sendable {
    /// `lineHandler` receives each stdout line as it arrives (used for
    /// `status:` updates). On timeout the process is terminated and the
    /// result carries `timedOut = true`.
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult
}

public struct LiveProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let collector = LineCollector(handler: lineHandler)

        // BOTH pipes are read as data arrives. stderr used to be read once,
        // after exit — which meant a child writing more than the pipe's
        // ~64 KB buffer to stderr blocked on write, could never exit, and was
        // reported as a timeout with its evidence truncated (`set -x` alone
        // can do it). Draining through the handler also closes the older
        // loss: the final bytes are consumed *before* EOF resolves the drain,
        // so the snapshot can never race a callback that has already read
        // them.
        let stdoutDrained = attach(stdoutPipe, as: .stdout, to: collector)
        let stderrDrained = attach(stderrPipe, as: .stderr, to: collector)

        try process.run()

        enum RaceOutcome { case exited, timeoutFired }
        let timedOut = await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                }
                return .exited
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timeoutFired
            }

            guard await group.next() == .timeoutFired, process.isRunning else {
                group.cancelAll()
                return false
            }

            // Timeout won. Collect the process *tree* before signalling
            // anything: killing only the interpreter left its children —
            // a hung curl, an installer — running as root after the item
            // was already recorded failed, and a later automatic attempt
            // then ran alongside the orphan. Collected first because the
            // moment the parent dies, orphans re-parent to launchd and
            // `pgrep -P` can no longer find them.
            let pid = process.processIdentifier
            let descendants = Self.descendantPIDs(of: pid)

            // Terminate, escalate to SIGKILL if ignored, then wait for the
            // real exit so the status code is meaningful.
            process.terminate()
            for child in descendants { kill(child, SIGTERM) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
                // Best effort; ESRCH for anything already gone. A pid could
                // in principle have been reused within these seconds — the
                // window is tiny, and the alternative is leaving root work
                // running unowned.
                for child in descendants { kill(child, SIGKILL) }
                return .timeoutFired
            }
            while let outcome = await group.next(), outcome != .exited {}
            group.cancelAll()
            return true
        }

        // Wait for both pipes to reach EOF so nothing a fast writer said in
        // its last moments is lost. Bounded: a child that handed its pipe to
        // a background grandchild (`something &` in a script that then exits)
        // keeps EOF from ever arriving, and that must stall an item for a
        // moment, not hang the run.
        await stdoutDrained.wait(upTo: .seconds(3))
        await stderrDrained.wait(upTo: .seconds(3))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let (stdout, stderr) = collector.snapshot()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr,
            timedOut: timedOut
        )
    }

    /// Streams one pipe into the collector until EOF; the returned drain
    /// resolves at EOF (`availableData` coming back empty).
    private func attach(
        _ pipe: Pipe,
        as stream: LineCollector.Stream,
        to collector: LineCollector
    ) -> PipeDrain {
        let drain = PipeDrain()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if stream == .stdout { collector.flushPendingLine() }
                drain.markFinished()
            } else {
                collector.ingest(data, stream: stream)
            }
        }
        return drain
    }

    /// Direct and transitive children of `pid`, walked breadth-first via
    /// `pgrep -P` (which takes a comma-separated parent list, so it is one
    /// subprocess per generation). Only called on the timeout path.
    static func descendantPIDs(of pid: pid_t, generationLimit: Int = 8) -> [pid_t] {
        var collected: [pid_t] = []
        var frontier = [pid]
        for _ in 0..<generationLimit {
            let parents = frontier.map(String.init).joined(separator: ",")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/pgrep")
            process.arguments = ["-P", parents]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return collected }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let children = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            guard !children.isEmpty else { return collected }
            collected.append(contentsOf: children)
            frontier = children
        }
        return collected
    }
}

/// EOF signal for one pipe: `markFinished()` on the reader side, a bounded
/// `wait(upTo:)` on the consumer side. Idempotent, single waiter.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func markFinished() {
        lock.lock()
        finished = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }

    /// Returns at EOF or after `grace`, whichever comes first.
    func wait(upTo grace: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForFinish() }
            group.addTask { try? await Task.sleep(for: grace) }
            await group.next()
            // The un-won task must be able to end, or the group would wait
            // for it forever: cancellation resolves the continuation below.
            group.cancelAll()
        }
    }

    private func waitForFinish() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            // May run before the continuation is stored; `finished` makes the
            // store-side resume immediately in that case.
            markFinished()
        }
    }
}

/// Accumulates pipe data and emits complete stdout lines to the handler.
private final class LineCollector: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let handler: (@Sendable (String) -> Void)?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var pendingLine = Data()

    init(handler: (@Sendable (String) -> Void)?) {
        self.handler = handler
    }

    func ingest(_ data: Data, stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout:
            stdoutData.append(data)
            guard handler != nil else { return }
            pendingLine.append(data)
            emitCompleteLines()
        case .stderr:
            stderrData.append(data)
        }
    }

    /// A final line without a trailing newline still reaches the handler —
    /// called once, at stdout EOF.
    func flushPendingLine() {
        lock.lock()
        defer { lock.unlock() }
        guard let handler, !pendingLine.isEmpty else { return }
        handler(String(decoding: pendingLine, as: UTF8.self))
        pendingLine.removeAll()
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func emitCompleteLines() {
        guard let handler else { return }
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            let line = pendingLine.subdata(in: pendingLine.startIndex..<newline)
            pendingLine.removeSubrange(pendingLine.startIndex...newline)
            handler(String(decoding: line, as: UTF8.self))
        }
    }
}

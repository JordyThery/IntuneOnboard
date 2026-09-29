import Foundation

/// The result of a finished or timed-out process.
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

/// Runs processes from argument arrays, never shell strings. Replaceable in
/// tests.
public protocol ProcessRunning: Sendable {
    /// `lineHandler` receives stdout line by line. On timeout the process is
    /// terminated and `timedOut` is true.
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

        // Read both pipes as data arrives. A child writing more than the pipe
        // buffer (about 64 KB) would otherwise block and never exit.
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

            // Timed out. Find descendants before signalling: once the parent
            // exits they are re-parented to launchd and no longer found.
            let pid = process.processIdentifier
            let descendants = Self.descendantPIDs(of: pid)

            // SIGTERM, then SIGKILL after five seconds, then wait for exit.
            process.terminate()
            for child in descendants { kill(child, SIGTERM) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
                // Best effort; already-exited processes are ignored.
                for child in descendants { kill(child, SIGKILL) }
                return .timeoutFired
            }
            while let outcome = await group.next(), outcome != .exited {}
            group.cancelAll()
            return true
        }

        // Wait for EOF on both pipes, but not indefinitely: a background
        // child can keep a pipe open after the process exits.
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

    /// Reads a pipe into the collector until EOF, which completes the drain.
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

    /// All descendants of `pid`, found with one `pgrep -P` per generation.
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

/// Signals EOF for one pipe, with a bounded wait. Single waiter.
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

    /// Returns at EOF or after `grace`.
    func wait(upTo grace: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForFinish() }
            group.addTask { try? await Task.sleep(for: grace) }
            await group.next()
            // Cancelling the other task ends its wait, so the group can finish.
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
            // May run before the continuation is stored; `finished` covers that.
            markFinished()
        }
    }
}

/// Collects pipe output and passes complete stdout lines to the handler.
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

    /// Passes a final line that has no trailing newline. Called at stdout EOF.
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

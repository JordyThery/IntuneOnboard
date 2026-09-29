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
        // Only stdout is read concurrently, because only stdout is streamed
        // (the `status:` lines). stderr is drained once, after the process
        // has gone: a readability handler on it raced the final snapshot —
        // an in-flight callback could append after the snapshot was taken,
        // and the bytes it had already consumed were simply lost, which is
        // how a failing script's reason went missing under load.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.ingest(handle.availableData, stream: .stdout)
        }

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

            // Timeout won: terminate, escalate to SIGKILL if ignored, then
            // wait for the real exit so the status code is meaningful.
            process.terminate()
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return .timeoutFired
            }
            while let outcome = await group.next(), outcome != .exited {}
            group.cancelAll()
            return true
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        collector.drain(
            stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        )

        let (stdout, stderr) = collector.snapshot()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr,
            timedOut: timedOut
        )
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
            guard let handler else { return }
            pendingLine.append(data)
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let line = pendingLine.subdata(in: pendingLine.startIndex..<newline)
                pendingLine.removeSubrange(pendingLine.startIndex...newline)
                handler(String(decoding: line, as: UTF8.self))
            }
        case .stderr:
            stderrData.append(data)
        }
    }

    func drain(_ stdoutRest: Data, _ stderrRest: Data) {
        ingest(stdoutRest, stream: .stdout)
        ingest(stderrRest, stream: .stderr)
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}

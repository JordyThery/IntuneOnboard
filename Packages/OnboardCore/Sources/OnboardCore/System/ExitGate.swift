import Foundation

/// Delays process exit until work in progress has finished.
///
/// The daemon waits briefly after its run so the UI can read the final
/// state. A retry started over XPC during that wait runs after `run()` has
/// returned, so exit waits for it, then waits again in case another follows.
public actor ExitGate {
    private let grace: Duration
    private let pollWhileWorking: Duration
    private var inFlight = 0
    private var latestExitCode: Int32

    /// - Parameters:
    ///   - initialExitCode: used if nothing else is recorded.
    ///   - grace: idle time before exit.
    ///   - pollWhileWorking: how often to check while work is running.
    public init(
        initialExitCode: Int32 = 0,
        grace: Duration = .seconds(5),
        pollWhileWorking: Duration = .seconds(1)
    ) {
        self.latestExitCode = initialExitCode
        self.grace = grace
        self.pollWhileWorking = pollWhileWorking
    }

    /// Sets the exit code; later work may replace it.
    public func record(exitCode: Int32) {
        latestExitCode = exitCode
    }

    /// Work that must finish before exit has started.
    public func beginWork() {
        inFlight += 1
    }

    /// That work finished, with its exit code.
    public func endWork(exitCode: Int32) {
        latestExitCode = exitCode
        inFlight = max(0, inFlight - 1)
    }

    /// The exit code, after a full grace period with no work running.
    public func settledExitCode() async -> Int32 {
        while true {
            try? await Task.sleep(for: grace)
            if inFlight == 0 { return latestExitCode }
            while inFlight > 0 {
                try? await Task.sleep(for: pollWhileWorking)
            }
            // Wait again, in case another request follows.
        }
    }
}

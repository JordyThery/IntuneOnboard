import Foundation

/// Decides when a process that has delivered its verdict may actually exit.
///
/// The daemon's problem, concretely: `run()` returns, and the process wants
/// to linger briefly so the UI can pull the final snapshot — but a **Try
/// again** arriving over XPC starts a whole engine pass *after* that return,
/// and a fixed sleep-then-`exit()` killed the pass mid-item: root work
/// terminated abruptly, then quietly re-run by the next spawn. The gate keeps
/// the grace period and makes it re-arm: work in flight holds the exit, and
/// every completed piece of work starts a fresh grace, in case another
/// request follows it.
///
/// Lives in OnboardCore rather than the daemon target so the race it exists
/// to prevent is coverable by unit tests; the daemon keeps only glue.
public actor ExitGate {
    private let grace: Duration
    private let pollWhileWorking: Duration
    private var inFlight = 0
    private var latestExitCode: Int32

    /// - Parameters:
    ///   - initialExitCode: what to exit with if nothing ever reports.
    ///   - grace: how long the process lingers once idle.
    ///   - pollWhileWorking: how often to re-check while work is in flight.
    ///     Tests shrink both; production keeps the defaults.
    public init(
        initialExitCode: Int32 = 0,
        grace: Duration = .seconds(5),
        pollWhileWorking: Duration = .seconds(1)
    ) {
        self.latestExitCode = initialExitCode
        self.grace = grace
        self.pollWhileWorking = pollWhileWorking
    }

    /// The verdict as of now; later work replaces it.
    public func record(exitCode: Int32) {
        latestExitCode = exitCode
    }

    /// A piece of work the exit must wait for has started.
    public func beginWork() {
        inFlight += 1
    }

    /// That work finished, with its own verdict.
    public func endWork(exitCode: Int32) {
        latestExitCode = exitCode
        inFlight = max(0, inFlight - 1)
    }

    /// Returns the exit code once a full grace period has passed with nothing
    /// in flight. Work that begins during a grace period re-arms it.
    public func settledExitCode() async -> Int32 {
        while true {
            try? await Task.sleep(for: grace)
            if inFlight == 0 { return latestExitCode }
            while inFlight > 0 {
                try? await Task.sleep(for: pollWhileWorking)
            }
            // Fresh grace period: another request may follow the one that
            // just finished.
        }
    }
}

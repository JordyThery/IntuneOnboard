import Foundation
import Testing
@testable import OnboardCore

/// The retry-vs-exit race, in miniature. On hardware this is: settle a Mac,
/// press Try again, and see whether the daemon's exit kills the retry — here
/// the same sequence runs in milliseconds against the extracted gate.
@Suite struct ExitGateTests {
    private func makeGate(initial: Int32 = 30) -> ExitGate {
        ExitGate(
            initialExitCode: initial,
            grace: .milliseconds(40),
            pollWhileWorking: .milliseconds(5)
        )
    }

    @Test func idleGateExitsWithTheRecordedVerdictAfterOneGrace() async {
        let gate = makeGate()
        await gate.record(exitCode: 7)
        let started = ContinuousClock.now
        let code = await gate.settledExitCode()
        #expect(code == 7)
        #expect(ContinuousClock.now - started >= .milliseconds(40), "the grace period must elapse")
    }

    /// The bug this type exists for: work beginning inside the grace period
    /// must hold the exit until it finishes — and the exit code is the
    /// *work's* verdict, not the stale one from before it ran.
    @Test func workInsideTheGraceHoldsTheExitAndReplacesTheVerdict() async throws {
        let gate = makeGate()
        await gate.record(exitCode: 30) // the settled failure

        // The retry arrives just after run() returned, as it does over XPC.
        await gate.beginWork()
        async let settled = gate.settledExitCode()

        // The engine pass outlives several grace periods — as a real one
        // (installing things) always would.
        try await Task.sleep(for: .milliseconds(150))
        await gate.endWork(exitCode: 0) // the retry fixed it

        let code = await settled
        #expect(code == 0, "the exit must carry the retry's verdict")
    }

    @Test func aSecondRetryReArmsTheGrace() async throws {
        let gate = makeGate()
        await gate.record(exitCode: 30)

        await gate.beginWork()
        async let settled = gate.settledExitCode()
        try await Task.sleep(for: .milliseconds(60))
        await gate.endWork(exitCode: 30) // first retry also failed

        // A second Try again lands inside the fresh grace period.
        await gate.beginWork()
        try await Task.sleep(for: .milliseconds(60))
        await gate.endWork(exitCode: 0)

        #expect(await settled == 0)
    }

    /// Overlapping work: the gate holds until *all* of it is done.
    @Test func overlappingWorkAllCountsAgainstTheExit() async throws {
        let gate = makeGate()
        await gate.beginWork()
        await gate.beginWork()
        async let settled = gate.settledExitCode()

        try await Task.sleep(for: .milliseconds(80))
        await gate.endWork(exitCode: 12)
        // Still one in flight — the gate must not release yet, so the second
        // verdict is the one that lands.
        try await Task.sleep(for: .milliseconds(80))
        await gate.endWork(exitCode: 0)

        #expect(await settled == 0)
    }
}

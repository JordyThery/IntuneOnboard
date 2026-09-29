import Foundation
import Testing
@testable import OnboardCore

/// Exit timing when a retry starts after the run has returned.
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

    /// Work started during the grace period delays exit, and its exit code
    /// replaces the earlier one.
    @Test func workInsideTheGraceHoldsTheExitAndReplacesTheVerdict() async throws {
        let gate = makeGate()
        await gate.record(exitCode: 30) // the settled failure

        // The retry starts just after run() returns.
        await gate.beginWork()
        async let settled = gate.settledExitCode()

        // The work outlasts several grace periods.
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

        // A second retry starts during the new grace period.
        await gate.beginWork()
        try await Task.sleep(for: .milliseconds(60))
        await gate.endWork(exitCode: 0)

        #expect(await settled == 0)
    }

    /// Exit waits for all concurrent work.
    @Test func overlappingWorkAllCountsAgainstTheExit() async throws {
        let gate = makeGate()
        await gate.beginWork()
        await gate.beginWork()
        async let settled = gate.settledExitCode()

        try await Task.sleep(for: .milliseconds(80))
        await gate.endWork(exitCode: 12)
        // One still running, so the later exit code applies.
        try await Task.sleep(for: .milliseconds(80))
        await gate.endWork(exitCode: 0)

        #expect(await settled == 0)
    }
}

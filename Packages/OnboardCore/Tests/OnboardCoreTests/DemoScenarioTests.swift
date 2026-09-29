import Foundation
import Testing
@testable import OnboardCore

@Suite struct DemoScenarioTests {
    @Test func startsInPreflightWithNothingRunning() {
        let snapshot = DemoScenario.snapshot(atElapsed: 0)
        #expect(snapshot.engineState == .preflight)
        #expect(snapshot.items.allSatisfy { $0.outcome == .pending })
    }

    @Test func midRunHasExactlyOneRunningItem() {
        let snapshot = DemoScenario.snapshot(atElapsed: 6)
        #expect(snapshot.engineState == .running)
        #expect(snapshot.items.filter { $0.outcome == .running }.count == 1)
        #expect(snapshot.items.first?.outcome == .skipped) // rosetta, already done
        #expect(snapshot.items.last?.outcome == .pending)  // finalize, not yet
    }

    @Test func aRunningScriptShowsItsStatusText() {
        let filevault = DemoScenario.steps.first { $0.id == "filevault" }!
        let snapshot = DemoScenario.snapshot(atElapsed: filevault.start + 1)
        let item = snapshot.items.first { $0.id == "filevault" }
        #expect(item?.outcome == .running)
        #expect(item?.statusText == "Enabling FileVault deferred enrollment")
    }

    @Test func endsWithOneFailureSoTheRetryPathIsReachable() {
        let snapshot = DemoScenario.snapshot(atElapsed: DemoScenario.totalSeconds + 1)
        #expect(snapshot.engineState == .completedWithErrors)
        #expect(snapshot.failedCount == 1)
        #expect(snapshot.items.first { $0.outcome == .failed }?.id == DemoScenario.failingStepID)
    }

    @Test func retryingClearsTheFailure() {
        let snapshot = DemoScenario.snapshot(atElapsed: DemoScenario.totalSeconds + 1, retried: true)
        #expect(snapshot.engineState == .completed)
        #expect(snapshot.failedCount == 0)
        #expect(snapshot.completedCount == DemoScenario.steps.count)
    }

    /// A retry rewinds to the failing item, so the user sees it run again
    /// rather than flip instantly to green.
    @Test func retryRebasesToTheFailingItem() {
        let snapshot = DemoScenario.snapshot(
            atElapsed: DemoScenario.retryRebaseSeconds + 1,
            retried: true
        )
        let item = snapshot.items.first { $0.id == DemoScenario.failingStepID }
        #expect(item?.outcome == .running)
        #expect(snapshot.engineState == .running)
    }

    @Test func timelineIsMonotonic() {
        // Completed count never goes down as the clock advances.
        var previous = 0
        for tick in stride(from: 0.0, through: DemoScenario.totalSeconds + 2, by: 0.5) {
            let completed = DemoScenario.snapshot(atElapsed: tick).completedCount
            #expect(completed >= previous)
            previous = completed
        }
        // Everything but the deliberately failing item.
        #expect(previous == DemoScenario.steps.count - 1)

        let final = DemoScenario.snapshot(atElapsed: DemoScenario.totalSeconds + 2)
        #expect(final.items.allSatisfy { $0.outcome.isTerminal })
    }

    /// The timeline and the demo profile are written by hand in two places;
    /// this is what catches them drifting apart.
    @Test func timelineAndConfigurationAgreeOnItems() {
        let configured = DemoScenario.configuration().provisioning?.items.map(\.id) ?? []
        #expect(configured == DemoScenario.steps.map(\.id))
    }

    @Test func demoConfigurationPassesTheRealValidator() {
        let errors = ConfigValidator.validate(
            DemoScenario.configuration(),
            // Inline scripts only, so nothing is stat-ed; fail closed anyway.
            fileChecks: .init(attributesOfItem: { _ in nil })
        )
        #expect(errors.isEmpty, "demo config is invalid: \(errors.map(\.description))")
    }

    @Test func demoSourceAdvancesAndRetriesOnce() async {
        let source = DemoProgressSource()
        let first = await source.currentSnapshot()
        #expect(first?.engineState == .preflight)

        #expect(await source.requestRetry())
        // Retry rebases the clock past the completed items.
        let afterRetry = await source.currentSnapshot()
        #expect(afterRetry?.completedCount ?? 0 >= 3)
        #expect(await source.requestRetry() == false)
    }
}

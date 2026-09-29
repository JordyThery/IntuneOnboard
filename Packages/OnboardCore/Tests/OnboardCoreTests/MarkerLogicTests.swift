import Testing
@testable import OnboardCore

@Suite struct MarkerLogicTests {
    @Test func allRequiredSuccessWritesMarker() {
        let records = [
            "a": ItemRecord(outcome: .success, status: .done),
            "b": ItemRecord(outcome: .success, status: .installed),
        ]
        #expect(MarkerLogic.markerEligible(requiredIDs: ["a", "b"], records: records))
    }

    @Test func skippedNeverBlocksEvenWhenRequired() {
        let records = [
            "a": ItemRecord(outcome: .success, status: .done),
            "b": ItemRecord(outcome: .skipped, status: .notNeeded),
        ]
        #expect(MarkerLogic.markerEligible(requiredIDs: ["a", "b"], records: records))
    }

    @Test func requiredFailureBlocks() {
        let records = [
            "a": ItemRecord(outcome: .success, status: .done),
            "b": ItemRecord(outcome: .failed, status: .downloadFailed),
        ]
        #expect(!MarkerLogic.markerEligible(requiredIDs: ["a", "b"], records: records))
    }

    @Test func optionalFailureDoesNotBlock() {
        let records = [
            "a": ItemRecord(outcome: .success, status: .done),
            "b": ItemRecord(outcome: .failed, status: .failed), // not in requiredIDs
        ]
        #expect(MarkerLogic.markerEligible(requiredIDs: ["a"], records: records))
    }

    @Test func unfinishedOrMissingBlocks() {
        let records = ["a": ItemRecord(outcome: .running, status: .installing)]
        #expect(!MarkerLogic.markerEligible(requiredIDs: ["a"], records: records))
        #expect(!MarkerLogic.markerEligible(requiredIDs: ["ghost"], records: records))
    }

}

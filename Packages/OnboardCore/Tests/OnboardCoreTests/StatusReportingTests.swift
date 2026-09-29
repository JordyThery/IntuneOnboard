import Foundation
import Testing
@testable import OnboardCLI
@testable import OnboardCore

/// `onboardd status` is what an administrator reads in Intune, one line per
/// Mac, across hundreds of them. Its wording is a product surface: "complete"
/// has to mean complete, and the device half finishing must not be reported
/// as the whole job being done.
@Suite struct StatusReportingTests {
    private func device(complete: Bool, items: [String: ItemOutcome]) -> DeviceState {
        var state = DeviceState()
        state.items = items.mapValues { ItemRecord(outcome: $0, status: $0 == .failed ? .failed : .done) }
        state.completedAt = complete ? .now : nil
        return state
    }

    private func user(complete: Bool, items: [String: ItemOutcome]) -> UserState {
        UserState(
            items: items.mapValues { ItemRecord(outcome: $0, status: .done) },
            completedAt: complete ? .now : nil
        )
    }

    @Test func nothingHasHappenedYet() {
        #expect(
            Status.singleLine(device: nil, onboarding: nil)
                == "provisioning: not started · onboarding: no console user"
        )
    }

    /// The case that matters: the device is done, the person at the keyboard
    /// is not. Reporting only the device half would call this Mac finished.
    @Test func aFinishedDeviceWithAnUnfinishedUserSaysSo() {
        let line = Status.singleLine(
            device: device(complete: true, items: ["a": .success, "b": .success]),
            onboarding: ("jordy", user(complete: false, items: ["wallpaper": .success]))
        )
        #expect(line == "provisioning: complete (2/2) · onboarding: in progress (jordy, 1/1)")
        #expect(!line.hasSuffix("complete"), "a half-done Mac must not read as complete")
    }

    @Test func bothStagesComplete() {
        let line = Status.singleLine(
            device: device(complete: true, items: ["a": .success]),
            onboarding: ("jordy", user(complete: true, items: ["wallpaper": .success]))
        )
        #expect(line == "provisioning: complete (1/1) · onboarding: complete (jordy)")
    }

    @Test func failuresAreCountedAndNamedAsSuch() {
        let line = Status.singleLine(
            device: device(complete: false, items: ["a": .success, "b": .failed]),
            onboarding: nil
        )
        #expect(line.hasPrefix("provisioning: failed (1 failed, 2/2 finished)"))
    }

    /// A user who has logged in but not yet done anything is distinct from a
    /// user who is partway through — and from no user at all.
    @Test func aUserWithNoStateYetIsNotTheSameAsNoUser() {
        let started = Status.singleLine(
            device: device(complete: true, items: ["a": .success]),
            onboarding: ("jordy", nil)
        )
        #expect(started.hasSuffix("onboarding: not started (jordy)"))

        let nobody = Status.singleLine(
            device: device(complete: true, items: ["a": .success]),
            onboarding: nil
        )
        #expect(nobody.hasSuffix("onboarding: no console user"))
    }

    /// One line, no newlines: Intune stores the value verbatim.
    @Test func theValueIsASingleLine() {
        let line = Status.singleLine(
            device: device(complete: true, items: ["a": .success]),
            onboarding: ("jordy", user(complete: true, items: [:]))
        )
        #expect(!line.contains("\n"))
        #expect(line.count < 256, "custom attribute values should stay short and readable")
    }

    /// Reporting runs as root, so "the current user" is root — the wrong
    /// answer. The store has to be resolved from the console user's home.
    @Test func aUsersStoreIsFoundByHomeDirectory() throws {
        let store = try #require(StateStore.forUser(named: NSUserName()))
        #expect(store.rootDirectory.path.hasPrefix(NSHomeDirectory()))
        #expect(store.rootDirectory.lastPathComponent == "IntuneOnboard")
        #expect(StateStore.forUser(named: "no-such-account-exists") == nil)
    }

    /// A Mac the profile deliberately refuses is not the same as one the
    /// package never reached, and in a list of hundreds "not started" cannot
    /// tell them apart.
    @Test func anIneligibleMacSaysSoInsteadOfNotStarted() {
        #expect(
            Status.singleLine(device: nil, onboarding: nil, ineligible: true)
                == "provisioning: not applicable (requireADE)"
        )
        // The flag is the only thing that changes the answer.
        #expect(
            Status.singleLine(device: nil, onboarding: nil, ineligible: false)
                != "provisioning: not applicable (requireADE)"
        )
    }
}

import Foundation
import Testing
@testable import OnboardCLI
@testable import OnboardCore

/// The single line reported by `onboardd status` and the custom attribute.
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

    /// Provisioning complete with onboarding outstanding is reported as such.
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

    /// Not started, in progress and no user are distinct.
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

    /// A single line.
    @Test func theValueIsASingleLine() {
        let line = Status.singleLine(
            device: device(complete: true, items: ["a": .success]),
            onboarding: ("jordy", user(complete: true, items: [:]))
        )
        #expect(!line.contains("\n"))
        #expect(line.count < 256, "custom attribute values should stay short and readable")
    }

    /// The console user's store is used, since reporting runs as root.
    @Test func aUsersStoreIsFoundByHomeDirectory() throws {
        let store = try #require(StateStore.forUser(named: NSUserName()))
        #expect(store.rootDirectory.path.hasPrefix(NSHomeDirectory()))
        #expect(store.rootDirectory.lastPathComponent == "IntuneOnboard")
        #expect(StateStore.forUser(named: "no-such-account-exists") == nil)
    }

    /// An ineligible Mac is reported distinctly.
    @Test func anIneligibleMacSaysSoInsteadOfNotStarted() {
        #expect(
            Status.singleLine(device: nil, onboarding: nil, ineligible: true)
                == "provisioning: not applicable (requireADE)"
        )
        // Only the flag differs.
        #expect(
            Status.singleLine(device: nil, onboarding: nil, ineligible: false)
                != "provisioning: not applicable (requireADE)"
        )
    }
}

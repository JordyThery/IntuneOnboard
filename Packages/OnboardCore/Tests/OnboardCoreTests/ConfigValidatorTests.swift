import Foundation
import Testing
@testable import OnboardCore

@Suite struct ConfigValidatorTests {
    private let rootOwnedChecks = ConfigValidator.FileChecks { _ in (ownerUID: 0, permissions: 0o755) }

    @Test func duplicateIDsAreReportedPerPhase() {
        let configuration = Configuration(
            provisioning: .init(items: [
                ProvisioningItem(id: "a", kind: .wait(seconds: 1, message: nil)),
                ProvisioningItem(id: "a", kind: .wait(seconds: 2, message: nil)),
            ]),
            onboarding: .init(items: [
                OnboardingItem(id: "a", kind: .demoteUser(exclude: [])), // same id, other phase: fine
            ])
        )
        let errors = ConfigValidator.validate(configuration, fileChecks: rootOwnedChecks)
        #expect(errors.count == 1)
        #expect(errors.first?.kind == .duplicateID("a"))
    }

    @Test func openValidatePathCombinationChecked() {
        let configuration = Configuration(onboarding: .init(items: [
            OnboardingItem(
                id: "register",
                kind: .open(target: .path("/Applications/Company Portal.app"), completion: .validatePath)
            ),
        ]))
        let errors = ConfigValidator.validate(configuration, fileChecks: rootOwnedChecks)
        #expect(errors.contains { if case .unreachableCombination = $0.kind { true } else { false } })
    }

    @Test func emptyDefaultAppsIsUnreachable() {
        let configuration = Configuration(onboarding: .init(items: [
            OnboardingItem(id: "defaults", kind: .defaultApps(.init())),
        ]))
        let errors = ConfigValidator.validate(configuration, fileChecks: rootOwnedChecks)
        #expect(errors.contains { if case .unreachableCombination = $0.kind { true } else { false } })
    }

    @Test func scriptPathOwnershipEnforced() {
        let configuration = Configuration(provisioning: .init(items: [
            ProvisioningItem(id: "s", kind: .script(.init(source: .path("/tmp/evil.sh")))),
        ]))

        let userOwned = ConfigValidator.FileChecks { _ in (ownerUID: 501, permissions: 0o755) }
        var errors = ConfigValidator.validate(configuration, fileChecks: userOwned)
        #expect(errors.contains { if case .scriptPathInsecure(_, let reason) = $0.kind { reason == "not owned by root" } else { false } })

        let worldWritable = ConfigValidator.FileChecks { _ in (ownerUID: 0, permissions: 0o777) }
        errors = ConfigValidator.validate(configuration, fileChecks: worldWritable)
        #expect(errors.contains { if case .scriptPathInsecure(_, let reason) = $0.kind { reason == "group/world-writable" } else { false } })

        errors = ConfigValidator.validate(configuration, fileChecks: rootOwnedChecks)
        #expect(errors.isEmpty)
    }
}

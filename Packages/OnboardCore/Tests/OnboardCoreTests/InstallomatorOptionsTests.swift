import Testing
@testable import OnboardCore

@Suite struct InstallomatorOptionsTests {
    @Test func bootstrapDefaultsAreValid() {
        for option in InstallomatorOptions.bootstrapDefaults {
            #expect(InstallomatorOptions.violation(of: option) == nil, "\(option)")
        }
    }

    @Test func allowsTypicalOptions() {
        #expect(InstallomatorOptions.violation(of: "NOTIFY=silent") == nil)
        #expect(InstallomatorOptions.violation(of: "REOPEN=no") == nil)
        #expect(InstallomatorOptions.violation(of: "PATH_VALUE=/Applications/App.app") == nil)
        #expect(InstallomatorOptions.violation(of: "OWNER=user@example.com") == nil)
    }

    @Test func rejectsDebugInAnyForm() {
        #expect(InstallomatorOptions.violation(of: "DEBUG=1") == .debugForbidden)
        #expect(InstallomatorOptions.violation(of: "DEBUG=0") == .debugForbidden)
        #expect(InstallomatorOptions.violation(of: "DEBUG=") == .debugForbidden)
    }

    @Test func rejectsShellShapes() {
        #expect(InstallomatorOptions.violation(of: "NOTIFY=silent; rm -rf /") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "$(whoami)=x") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "lower=case") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "NOOPTION") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "KEY=`id`") == .disallowedShape)
    }

    @Test func debugZeroIsAlwaysLast() {
        let arguments = InstallomatorOptions.effectiveArguments(
            defaults: ["NOTIFY=silent"],
            itemOptions: ["INSTALL=force"]
        )
        #expect(arguments == ["NOTIFY=silent", "INSTALL=force", "DEBUG=0"])
        #expect(arguments.last == "DEBUG=0")
    }
}

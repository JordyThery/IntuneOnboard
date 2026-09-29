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

    /// Installomator `eval`s each option, and `eval KEY=a b` parses as the
    /// assignment `KEY=a` followed by the *command* `b` — so a bare value may
    /// not contain a space. A value that needs one arrives quoted, which
    /// `eval` reads back as a single assignment; the quoted form still bans
    /// everything that would end the quote or expand inside it.
    @Test func spacesRequireTheQuotedForm() {
        // Bare spaces: part of the value would run as a command.
        #expect(InstallomatorOptions.violation(of: "LOGO=/tmp/a b") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "NOTIFY=silent INSTALL=force") == .disallowedShape)

        // Quoted values may carry spaces…
        #expect(InstallomatorOptions.violation(of: "LOGO=\"/Library/Application Support/x.png\"") == nil)

        // …but nothing that escapes the quote or expands inside it.
        #expect(InstallomatorOptions.violation(of: "KEY=\"a\" b \"c\"") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "KEY=\"$(whoami)\"") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "KEY=\"`id`\"") == .disallowedShape)
        #expect(InstallomatorOptions.violation(of: "KEY=\"a\\\"b\"") == .disallowedShape)
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

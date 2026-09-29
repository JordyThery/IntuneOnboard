import Foundation
import Testing
@testable import OnboardCore

@Suite struct NameTemplateTests {
    private func render(_ template: String, serial: String? = "C304JQC4KM") throws -> String? {
        try NameTemplate.parse(template).render { token in
            switch token {
            case .serial: serial
            case .udid: "0A1B2C3D-0000-1111-2222-333344445555"
            case .model: "MacBook Air"
            case .modelShort: "MacBook"
            }
        }
    }

    @Test func literalAndTokenSegmentsRender() throws {
        #expect(try render("L9P-%serial%") == "L9P-C304JQC4KM")
        #expect(try render("%model-short%-%serial:-4%") == "MacBook-C4KM")
        #expect(try render("plain name") == "plain name")
    }

    @Test func modifiersTakeFirstLastAndCenter() throws {
        #expect(try render("%serial:4%") == "C304")
        #expect(try render("%serial:-4%") == "C4KM")
        // 10 chars, center 6: drop 2 each side.
        #expect(try render("%serial:=6%") == "04JQC4")
        // Odd surplus comes off the end (start index rounds down).
        #expect(try render("%serial:=6%", serial: "ABCDEFGHIJK") == "CDEFGH")
        // A modifier longer than the value keeps the whole value.
        #expect(try render("%serial:99%") == "C304JQC4KM")
    }

    @Test func doublePercentEscapes() throws {
        #expect(try render("100%% %model%") == "100% MacBook Air")
    }

    @Test func malformedTemplatesAreParseErrors() {
        #expect(throws: NameTemplate.ParseError.unknownToken("serail")) {
            try NameTemplate.parse("L9P-%serail%")
        }
        #expect(throws: NameTemplate.ParseError.unterminatedToken) {
            try NameTemplate.parse("50% off")
        }
        #expect(throws: NameTemplate.ParseError.invalidModifier("x")) {
            try NameTemplate.parse("%serial:x%")
        }
        #expect(throws: NameTemplate.ParseError.invalidModifier("0")) {
            try NameTemplate.parse("%serial:0%")
        }
        #expect(throws: NameTemplate.ParseError.empty) {
            try NameTemplate.parse("")
        }
    }

    @Test func missingValueRendersNothingRatherThanAPartialName() throws {
        #expect(try render("L9P-%serial%", serial: nil) == nil)
        #expect(try render("L9P-%serial%", serial: "") == nil)
    }

    @Test func localHostNameIsBonjourSafe() {
        // The apostrophe drops rather than hyphenates — the same shape macOS
        // itself produces for "Jordy's MacBook Air".
        #expect(NameTemplate.localHostName(from: "Jordy's MacBook Air") == "Jordys-MacBook-Air")
        #expect(NameTemplate.localHostName(from: "L9P_C304 JQC4KM") == "L9P-C304-JQC4KM")
        #expect(NameTemplate.localHostName(from: "--weird--") == "weird")
        #expect(NameTemplate.localHostName(from: "···") == nil)
        // Truncation at 63 must not leave a trailing hyphen behind.
        let long = String(repeating: "a", count: 62) + "-bcd"
        #expect(NameTemplate.localHostName(from: long) == String(repeating: "a", count: 62))
    }
}

@Suite struct DeviceNamerTests {
    private func namer(runner: FakeProcessRunner, serial: String? = "C304JQC4KM") -> DeviceNamer {
        DeviceNamer(runner: runner) { token in
            token == .serial ? serial : "unused"
        }
    }

    @Test func setsAllThreeNamesThroughScutil() async throws {
        let runner = FakeProcessRunner()
        let template = try NameTemplate.parse("L9P %serial:-4%")
        let outcome = await namer(runner: runner).apply(template: template, dryRun: false)

        #expect(outcome == .named(computerName: "L9P C4KM", localHostName: "L9P-C4KM"))
        #expect(runner.invocations.map(\.arguments) == [
            ["--set", "ComputerName", "L9P C4KM"],
            ["--set", "LocalHostName", "L9P-C4KM"],
            ["--set", "HostName", "L9P-C4KM"],
        ])
        #expect(runner.invocations.allSatisfy { $0.executable == "/usr/sbin/scutil" })
    }

    @Test func dryRunRendersButNeverTouchesScutil() async throws {
        let runner = FakeProcessRunner()
        let template = try NameTemplate.parse("L9P-%serial%")
        let outcome = await namer(runner: runner).apply(template: template, dryRun: true)

        #expect(outcome == .dryRun(computerName: "L9P-C304JQC4KM"))
        #expect(runner.invocations.isEmpty)
    }

    @Test func missingValueNamesNothing() async throws {
        let runner = FakeProcessRunner()
        let template = try NameTemplate.parse("L9P-%serial%")
        let outcome = await namer(runner: runner, serial: nil).apply(template: template, dryRun: false)

        #expect(outcome == .valueUnavailable)
        #expect(runner.invocations.isEmpty)
    }

    @Test func scutilFailureIsReportedNotSwallowed() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false),
        ])
        let template = try NameTemplate.parse("%serial%")
        let outcome = await namer(runner: runner).apply(template: template, dryRun: false)
        #expect(outcome == .failed("scutil --set ComputerName exited 1"))
    }
}

import Testing
@testable import OnboardCore

@Suite struct IconSpecTests {
    @Test func parsesAllForms() {
        #expect(IconSpec(configString: "symbol:square.grid.2x2") == .symbol("square.grid.2x2"))
        #expect(IconSpec(configString: "/Applications/Safari.app") == .path("/Applications/Safari.app"))
        #expect(IconSpec(configString: "bundleid:com.microsoft.edgemac") == .bundleID("com.microsoft.edgemac"))
        if case .remote(let url)? = IconSpec(configString: "https://example.com/logo.png") {
            #expect(url.host() == "example.com")
        } else {
            Issue.record("https URL should parse as .remote")
        }
    }

    @Test func rejectsInsecureOrMalformed() {
        #expect(IconSpec(configString: "http://example.com/logo.png") == nil)
        #expect(IconSpec(configString: "symbol:") == nil)
        #expect(IconSpec(configString: "bundleid:") == nil)
        #expect(IconSpec(configString: "relative/path.png") == nil)
    }
}

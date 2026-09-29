import Testing
@testable import OnboardCore

@Suite struct LocalizedTextTests {
    let table = LocalizedText(localized: [
        "en": "Questions? Contact IT.",
        "nl": "Vragen? Contacteer IT.",
        "fr": "Des questions ? Contactez l’IT.",
    ])

    @Test func exactMatch() {
        #expect(table.resolved(preferredLanguages: ["nl"]) == "Vragen? Contacteer IT.")
    }

    @Test func baseLanguageFallback() {
        #expect(table.resolved(preferredLanguages: ["nl-BE"]) == "Vragen? Contacteer IT.")
        #expect(table.resolved(preferredLanguages: ["fr_BE"]) == "Des questions ? Contactez l’IT.")
    }

    @Test func englishFallback() {
        #expect(table.resolved(preferredLanguages: ["de-DE"]) == "Questions? Contact IT.")
    }

    @Test func firstKeyFallbackIsDeterministic() {
        let noEnglish = LocalizedText(localized: ["nl": "A", "fr": "B"])
        #expect(noEnglish.resolved(preferredLanguages: ["de"]) == "B") // "fr" < "nl"
    }

    @Test func plainStringPassesThrough() {
        let plain = LocalizedText(plain: "Hello")
        #expect(plain.resolved(preferredLanguages: ["nl"]) == "Hello")
    }

    @Test func plistParsing() {
        #expect(LocalizedText(plistValue: "hi") != nil)
        #expect(LocalizedText(plistValue: ["en": "hi"]) != nil)
        #expect(LocalizedText(plistValue: 42) == nil)
        #expect(LocalizedText(plistValue: [String: String]()) == nil)
    }
}

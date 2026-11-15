import Testing
@testable import OnboardCore

@Suite struct LocalizedTextTests {
    let table = LocalizedText(localized: [
        "en": "Questions? Contact IT.",
        "nl": "Vragen? Contacteer IT.",
        "fr": "Des questions ? Contactez l’IT.",
        "sv": "Frågor? Kontakta IT.",
    ])

    @Test func swedishResolvesFromARegionalMac() {
        #expect(table.resolved(preferredLanguages: ["sv-SE", "en-SE"]) == "Frågor? Kontakta IT.")
        #expect(table.resolved(preferredLanguages: ["sv_FI"]) == "Frågor? Kontakta IT.")
    }

    /// Hand-written profile keys: `sv_SE`, `sv-SE` or `SV`.
    @Test func profileKeysMatchRegardlessOfSpelling() {
        let regional = LocalizedText(localized: ["en": "Hi", "sv_SE": "Hej"])
        #expect(regional.resolved(preferredLanguages: ["sv-SE"]) == "Hej")
        #expect(regional.resolved(preferredLanguages: ["sv"]) == "Hej")
        #expect(regional.resolved(preferredLanguages: ["sv-FI"]) == "Hej")
        #expect(LocalizedText(localized: ["en": "Hi", "SV": "Hej"]).resolved(preferredLanguages: ["sv-SE"]) == "Hej")
    }

    /// The script subtag is tried before the bare language.
    @Test func scriptSubtagIsTriedBeforeTheBaseLanguage() {
        let chinese = LocalizedText(localized: ["en": "Hi", "zh": "base", "zh-Hans": "简体"])
        #expect(chinese.resolved(preferredLanguages: ["zh-Hans-CN"]) == "简体")
    }

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

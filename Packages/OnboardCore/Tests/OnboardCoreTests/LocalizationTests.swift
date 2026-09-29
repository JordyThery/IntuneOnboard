import Foundation
import Testing
@testable import OnboardCore
@testable import OnboardUI

/// Localization in a Swift package fails *silently*: without the module's own
/// bundle the lookup goes to `Bundle.main`, finds nothing, and returns the key
/// — which in the source language is indistinguishable from a translation that
/// worked. So these tests resolve strings in Dutch and French, where a
/// fallback would be obvious.
@Suite struct LocalizationTests {
    private var catalogURL: URL {
        // …/Tests/OnboardCoreTests/LocalizationTests.swift → the package root
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OnboardUI/Resources/Localizable.xcstrings")
    }

    private func resolved(_ resource: LocalizedStringResource, in identifier: String) -> String {
        var localized = resource
        localized.locale = Locale(identifier: identifier)
        return String(localized: localized)
    }

    @Test func provisioningStringsResolveFromTheModuleCatalog() {
        #expect(resolved(ProvisioningStrings.completed, in: "en") == "Your Mac is ready")
        #expect(resolved(ProvisioningStrings.completed, in: "nl") == "Je Mac is klaar")
        #expect(resolved(ProvisioningStrings.completed, in: "fr") == "Votre Mac est prêt")
    }

    /// Over Setup Assistant a failed run has no buttons at all, so this
    /// sentence is the only thing on screen telling whoever is holding the
    /// Mac what to do next. It has to arrive translated, with the
    /// organization's own contact line carried through untouched.
    @Test func theSupportLineIsTranslatedAndKeepsTheContactDetails() {
        let details = "IT service desk · +32 (0)3 123 45 67"
        let nl = resolved(ProvisioningStrings.contactSupport(details: details), in: "nl")
        #expect(nl.contains(details))
        #expect(nl.contains("IT-helpdesk") || nl.contains("contact op"))

        let fr = resolved(ProvisioningStrings.contactSupportGeneric, in: "fr")
        #expect(fr.contains("assistance informatique"))
    }

    @Test func onboardingStringsResolveFromTheModuleCatalog() {
        #expect(resolved(OnboardingStrings.continueButton, in: "nl") == "Doorgaan")
        #expect(resolved(OnboardingStrings.continueButton, in: "fr") == "Continuer")
        #expect(resolved(OnboardingStrings.keepCurrent, in: "nl") == "Huidige behouden")
    }

    /// Statuses come from the daemon as codes precisely so they can be
    /// translated here.
    @Test func itemStatusesAreTranslated() {
        #expect(resolved(ProvisioningStrings.label(for: .downloading), in: "nl") == "Downloaden…")
        #expect(resolved(ProvisioningStrings.label(for: .awaitingUser), in: "fr") == "En attente de votre action")
        #expect(resolved(ProvisioningStrings.label(for: .hashMismatch), in: "nl") == "Verificatie mislukt")
    }

    /// The "About this Mac" rows. These were English on hardware after the
    /// first pass: they were passed to a helper as `LocalizedStringKey`
    /// literals, which look localizable and resolve against `Bundle.main`,
    /// where a package's keys do not exist.
    @Test func theMacDetailRowsAreTranslated() {
        #expect(resolved(ProvisioningStrings.memory, in: "nl") == "Geheugen")
        #expect(resolved(ProvisioningStrings.storage, in: "fr") == "Stockage")
        #expect(resolved(ProvisioningStrings.serialNumber, in: "nl") == "Serienummer")
        #expect(resolved(ProvisioningStrings.elapsed, in: "fr") == "Écoulé")
        #expect(resolved(ProvisioningStrings.chip, in: "fr") == "Puce")
        #expect(resolved(ProvisioningStrings.model, in: "nl") == "Model")
    }

    /// Interpolated strings keep their arguments in the order each language
    /// wants, which is the reason the translations use positional specifiers.
    @Test func interpolationSurvivesTranslation() {
        #expect(resolved(ProvisioningStrings.progressCaption(completed: 2, total: 7), in: "en") == "2 of 7 complete")
        #expect(resolved(ProvisioningStrings.progressCaption(completed: 2, total: 7), in: "nl") == "2 van 7 voltooid")
        #expect(resolved(ProvisioningStrings.progressCaption(completed: 2, total: 7), in: "fr") == "2 sur 7 terminés")

        #expect(
            resolved(ProvisioningStrings.stepCaption(item: "Microsoft Edge", step: 2, total: 4), in: "nl")
                == "Microsoft Edge (stap 2 van 4)"
        )
        #expect(
            resolved(OnboardingStrings.dockOutcome(added: 5, skipped: 1), in: "fr")
                == "Terminé (5 ajoutés, 1 ignorés)"
        )
    }

    /// Singular and plural are the catalog's job: a ternary in Swift would
    /// impose English's two categories on every language.
    @Test func pluralsAgreeWithTheirNumber() {
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "en") == "1 item failed")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "en") == "3 items failed")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "nl") == "1 onderdeel is mislukt")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "nl") == "3 onderdelen zijn mislukt")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "fr") == "1 élément a échoué")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "fr") == "3 éléments ont échoué")

        // The provisioning header's failure count.
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "en") == "1 needs attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "en") == "2 need attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "nl") == "1 vraagt aandacht")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "nl") == "2 vragen aandacht")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "fr") == "1 demande votre attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "fr") == "2 demandent votre attention")

        // The onboarding header's counter.
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "en") == "1 of 6 done")
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "nl") == "1 van 6 voltooid")
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "fr") == "1 sur 6 terminées")
    }

    /// The failure line is one sentence with the reason inside it, not a
    /// localized prefix concatenated with a message — word order differs.
    @Test func theFailureLineIsASingleSentence() {
        let sentence = resolved(OnboardingStrings.failure(message: "desktoppr exited 1"), in: "nl")
        #expect(sentence == "Deze stap is niet voltooid: desktoppr exited 1")
    }

    /// The guard that matters for every string added from here on: shipping
    /// one without nl and fr is a silent English leak into a translated UI.
    @Test func everyStringIsTranslatedIntoEveryLanguage() throws {
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")

        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(strings.count >= 60, "the catalog lost entries; it holds only \(strings.count)")

        for (key, entry) in strings {
            let localizations = try #require(entry["localizations"] as? [String: Any], "`\(key)` has no localizations")
            for language in ["en", "nl", "fr"] {
                #expect(localizations[language] != nil, "`\(key)` is missing \(language)")
            }
            #expect(entry["comment"] is String, "`\(key)` has no comment for whoever translates it next")
        }
    }
}

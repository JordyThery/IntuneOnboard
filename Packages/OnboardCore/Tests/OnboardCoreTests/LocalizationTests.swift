import Foundation
import Testing
@testable import OnboardCore
@testable import OnboardUI

/// Resolves strings in Dutch and French: a failed package lookup returns the
/// English key, which would pass unnoticed in English.
@Suite struct LocalizationTests {
    private var catalogURL: URL {
        // The package root, relative to this file.
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

    /// The failure message is translated and keeps the organization's text.
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

    /// Status texts are translated.
    @Test func itemStatusesAreTranslated() {
        #expect(resolved(ProvisioningStrings.label(for: .downloading), in: "nl") == "Downloaden…")
        #expect(resolved(ProvisioningStrings.label(for: .awaitingUser), in: "fr") == "En attente de votre action")
        #expect(resolved(ProvisioningStrings.label(for: .hashMismatch), in: "nl") == "Verificatie mislukt")
    }

    /// "About this Mac" labels are translated.
    @Test func theMacDetailRowsAreTranslated() {
        #expect(resolved(ProvisioningStrings.memory, in: "nl") == "Geheugen")
        #expect(resolved(ProvisioningStrings.storage, in: "fr") == "Stockage")
        #expect(resolved(ProvisioningStrings.serialNumber, in: "nl") == "Serienummer")
        #expect(resolved(ProvisioningStrings.elapsed, in: "fr") == "Écoulé")
        #expect(resolved(ProvisioningStrings.chip, in: "fr") == "Puce")
        #expect(resolved(ProvisioningStrings.model, in: "nl") == "Model")
    }

    /// Interpolated strings use positional arguments.
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

    /// Plural forms come from the String Catalog.
    @Test func pluralsAgreeWithTheirNumber() {
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "en") == "1 item failed")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "en") == "3 items failed")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "nl") == "1 onderdeel is mislukt")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "nl") == "3 onderdelen zijn mislukt")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 1), in: "fr") == "1 élément a échoué")
        #expect(resolved(ProvisioningStrings.failureCaption(count: 3), in: "fr") == "3 éléments ont échoué")

        // Provisioning failure count.
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "en") == "1 needs attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "en") == "2 need attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "nl") == "1 vraagt aandacht")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "nl") == "2 vragen aandacht")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 1), in: "fr") == "1 demande votre attention")
        #expect(resolved(ProvisioningStrings.needsAttention(count: 2), in: "fr") == "2 demandent votre attention")

        // Onboarding counter.
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "en") == "1 of 6 done")
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "nl") == "1 van 6 voltooid")
        #expect(resolved(OnboardingStrings.doneCounter(completed: 1, total: 6), in: "fr") == "1 sur 6 terminées")
    }

    /// The failure line is one translated sentence.
    @Test func theFailureLineIsASingleSentence() {
        let sentence = resolved(OnboardingStrings.failure(message: "desktoppr exited 1"), in: "nl")
        #expect(sentence == "Deze stap is niet voltooid: desktoppr exited 1")
    }

    /// Every string has English, Dutch and French translations and a comment.
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

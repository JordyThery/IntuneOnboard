import OnboardCore
import SwiftUI

/// Onboarding's built-in strings.
enum OnboardingStrings {
    /// Not localized. `onboarding.title` overrides it.
    static var defaultTitle: String { "Intune Onboard" }

    static var defaultMessage: String {
        .module(localized: "Configure your new Mac!", comment: "Subtitle under the product name in the sidebar, when the profile sets no message of its own.")
    }

    static var continueButton: LocalizedStringResource {
        .module("Continue", comment: "The primary button: accepts the current step and moves to the next one.")
    }
    static var done: LocalizedStringResource {
        .module("Done", comment: "The primary button once every step is finished; closes the window.")
    }
    static var completedSection: LocalizedStringResource {
        .module("Completed", comment: "Accessibility value on a finished step's card.")
    }
    /// Progress through the steps.
    static func doneCounter(completed: Int, total: Int) -> LocalizedStringResource {
        .module(
            "\(completed) of \(total) done",
            comment: "Progress under the onboarding title. The first number is how many steps are finished, the second is how many there are."
        )
    }
    static var working: LocalizedStringResource {
        .module("Working…", comment: "Shown while a step is being carried out.")
    }
    static var keepCurrent: LocalizedStringResource {
        .module("Keep current", comment: "Button that leaves the setting as the user already has it.")
    }
    static var currentDefault: LocalizedStringResource {
        .module("Current", comment: "Caption under the app icon that is already the default for this kind of file or link.")
    }
    static var openButtonFallback: LocalizedStringResource {
        .module("Open", comment: "Button that launches an app, when the profile gives no label of its own.")
    }
    static var confirm: LocalizedStringResource {
        .module("Confirm", comment: "Button that applies the setting shown.")
    }
    static var appsNotInstalled: LocalizedStringResource {
        .module("The apps for this step aren't installed on this Mac.", comment: "Explains why a step has nothing to do: none of the apps it manages are present.")
    }
    static var retry: LocalizedStringResource {
        .module("Try again", comment: "Button that re-runs a step that failed.")
    }

    /// A single sentence, so translations control word order.
    static func failure(message: String) -> LocalizedStringResource {
        .module("This step didn't finish: \(message)", comment: "Shown under a failed step. The variable is the reason, which comes from the system and is not translated.")
    }

    static func dockStrategyLabel(_ action: OnboardingItem.DockStrategy) -> LocalizedStringResource {
        switch action {
        case .keep:
            .module("Keep the current Dock", comment: "Choice: leave the Dock exactly as it is.")
        case .add:
            .module("Add recommended items to current Dock", comment: "Choice: keep what is in the Dock and add the company's apps to it.")
        case .replace:
            .module("Replace current Dock with recommendation", comment: "Choice: clear the Dock and put the company's apps in it.")
        }
    }

    /// The Dock result with counts.
    static func dockOutcome(added: Int, skipped: Int) -> LocalizedStringResource {
        .module(
            "Done (\(added) added, \(skipped) skipped)",
            comment: "Result of the Dock step. The first number is how many apps were added, the second how many were skipped because they are not installed."
        )
    }
}

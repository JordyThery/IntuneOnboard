import OnboardCore
import SwiftUI

/// Every user-facing string in the provisioning UI, in one file on purpose:
/// the daemon emits status *codes* (`StatusKind`) and the UI turns them into
/// text, so the translations live here and no view has to know about them.
///
/// `LocalizedStringResource`, not `LocalizedStringKey`: these strings come
/// from a package's own catalog, and only the resource type carries the
/// bundle that makes that lookup work. See `LocalizedStringResource.module`.
enum ProvisioningStrings {
    static var defaultTitle: LocalizedStringResource {
        .module("Setting up your Mac", comment: "Heading on the provisioning card while the run is in progress, when the profile sets no title of its own.")
    }
    static var defaultMessage: LocalizedStringResource {
        .module("This takes a few minutes. Keep the Mac plugged in and connected to the network.", comment: "Reassurance under the provisioning heading.")
    }

    static var connecting: LocalizedStringResource {
        .module("Connecting to the onboarding service…", comment: "Status line: the app is waiting for the background service to answer.")
    }
    static var waitingForConfig: LocalizedStringResource {
        .module("Waiting for the configuration profile…", comment: "Status line: the Mac has no configuration profile yet, which arrives from device management.")
    }
    static var preflight: LocalizedStringResource {
        .module("Checking this Mac…", comment: "Status line: verifying the Mac meets the requirements before installing anything.")
    }
    static var completed: LocalizedStringResource {
        .module("Your Mac is ready", comment: "Headline when everything finished successfully.")
    }
    static var completedWithErrors: LocalizedStringResource {
        .module("Setup finished with problems", comment: "Headline when the run finished but one or more items failed.")
    }
    static var preflightFailed: LocalizedStringResource {
        .module("Setup can't start on this Mac", comment: "Headline when the pre-install checks failed, so nothing was installed.")
    }

    static var retry: LocalizedStringResource {
        .module("Retry failed items", comment: "Button that runs the failed items again.")
    }
    static var done: LocalizedStringResource {
        .module("Done", comment: "Button that closes the provisioning card.")
    }
    static var continueAnyway: LocalizedStringResource {
        .module("Continue anyway", comment: "Button that dismisses the card despite failures, when the profile allows it.")
    }

    static var aboutThisMac: LocalizedStringResource {
        .module("About this Mac…", comment: "Link that opens details about this Mac: model, serial number, macOS version.")
    }
    static var helpButton: LocalizedStringResource {
        .module("Help", comment: "Accessibility label for the circled question mark that shows the support details.")
    }
    // "About this Mac" rows. `macOS` is missing on purpose: it is Apple's
    // product name, so the view passes it verbatim rather than offering it
    // for translation.
    static var chip: LocalizedStringResource {
        .module("Chip", comment: "Label in the Mac's details: the processor, e.g. \"Apple M4\".")
    }
    static var memory: LocalizedStringResource {
        .module("Memory", comment: "Label in the Mac's details: installed RAM.")
    }
    static var storage: LocalizedStringResource {
        .module("Storage", comment: "Label in the Mac's details: disk size.")
    }
    static var model: LocalizedStringResource {
        .module("Model", comment: "Label in the Mac's details: the model identifier, e.g. \"Mac15,13\".")
    }
    static var serialNumber: LocalizedStringResource {
        .module("Serial number", comment: "Label in the Mac's details: the hardware serial number.")
    }
    static var elapsed: LocalizedStringResource {
        .module("Elapsed", comment: "Label in the Mac's details: how long the run has been going.")
    }

    static var network: LocalizedStringResource {
        .module("Network", comment: "Label for the network row in the Mac's details.")
    }
    static var online: LocalizedStringResource {
        .module("Connected", comment: "Network state: the Mac can reach the network.")
    }
    static var offline: LocalizedStringResource {
        .module("Not connected", comment: "Network state: the Mac cannot reach the network.")
    }

    static var logsTitle: LocalizedStringResource {
        .module("Onboarding logs", comment: "Title of the window that shows the log files.")
    }
    static var summarize: LocalizedStringResource {
        .module("Summarize", comment: "Checkbox that hides log lines unrelated to enrollment.")
    }
    static var summarizeHelp: LocalizedStringResource {
        .module("Show only the lines relevant to enrollment", comment: "Tooltip for the Summarize checkbox.")
    }
    static var alreadyTerse: LocalizedStringResource {
        .module("This log is already summarized", comment: "Tooltip explaining why Summarize is disabled for this log.")
    }
    static var exportLogs: LocalizedStringResource {
        .module("Export…", comment: "Button that copies the logs to a folder the technician can collect.")
    }
    static var exportFailed: LocalizedStringResource {
        .module("Could not write the logs to /Users/Shared.", comment: "Error shown when exporting the logs failed. Leave the path as it is.")
    }
    static var close: LocalizedStringResource {
        .module("Close", comment: "Button that closes the log window.")
    }
    static var exported: LocalizedStringResource {
        .module("Exported to /Users/Shared", comment: "Confirmation that the logs were written. Leave the path as it is.")
    }
    static var logUnavailableText: LocalizedStringResource {
        .module("Nothing logged here yet.", comment: "Shown in place of an empty log.")
    }
    /// The Intune tab is empty for a good reason worth stating: its agent is
    /// installed by Intune partway through enrollment, so "nothing here"
    /// during early provisioning is the expected state rather than a fault.
    static var intuneLogUnavailableText: LocalizedStringResource {
        .module(
            "No Intune log yet — its agent is installed during enrollment. Export to capture the MDM entries from the system log.",
            comment: "Shown in place of an empty log for the device-management tab. \"Intune\" and \"MDM\" are product terms; keep them."
        )
    }

    /// The card's vendor credit.
    static var credit: LocalizedStringResource {
        .module("Created by Jordy Thery with ❤️", comment: "Credit line in the card's footer. The name is a person's and is not translated.")
    }

    static func progressCaption(completed: Int, total: Int) -> LocalizedStringResource {
        .module(
            "\(completed) of \(total) complete",
            comment: "Progress under the bar. The first number is how many items finished, the second is how many there are."
        )
    }

    /// "Microsoft Edge (step 2 of 4)" — the item being worked on, with its
    /// place in the run.
    static func stepCaption(item: String, step: Int, total: Int) -> LocalizedStringResource {
        .module(
            "\(item) (step \(step) of \(total))",
            comment: "What is being installed right now. First the item's name, then its position in the run, then the number of items."
        )
    }

    /// Singular and plural are the catalog's job, not a ternary's: the
    /// categories differ per language, so the entry carries plural variations
    /// and this only supplies the number.
    static func failureCaption(count: Int) -> LocalizedStringResource {
        .module("\(count) items failed", comment: "How many items did not succeed.")
    }

    /// The header's failure count, next to "N of M complete".
    static func needsAttention(count: Int) -> LocalizedStringResource {
        .module("\(count) needs attention", comment: "In the header, how many items failed and need someone to look at them. Carries plural variants per language.")
    }

    /// One sentence carrying the organization's own contact details, rather
    /// than a fixed prefix glued to them: the two halves do not keep this
    /// order in every language.
    static func contactSupport(details: String) -> LocalizedStringResource {
        .module(
            "Your Mac still works. Please contact IT to finish setting it up: \(details)",
            comment: "Shown under a failed provisioning run. The variable is the organization's own support line, from the profile, and is not translated."
        )
    }

    /// The same message for a profile that configures no `supportText`.
    static var contactSupportGeneric: LocalizedStringResource {
        .module(
            "Your Mac still works. Please contact your IT service desk to finish setting it up.",
            comment: "Shown under a failed provisioning run when the profile gives no support contact details."
        )
    }

    /// The headline for a phase; nil means the configured title is shown
    /// instead (the run is still in progress and has its own heading).
    static func headline(for phase: ProvisioningDisplay.Phase) -> LocalizedStringResource? {
        switch phase {
        case .connecting, .waitingForConfig, .preflight, .running: nil
        case .completed: completed
        case .completedWithErrors: completedWithErrors
        case .preflightFailed: preflightFailed
        }
    }

    /// The "what's happening right now" line under the progress bar.
    static func activity(for phase: ProvisioningDisplay.Phase) -> LocalizedStringResource? {
        switch phase {
        case .connecting: connecting
        case .waitingForConfig: waitingForConfig
        case .preflight: preflight
        case .running, .completed, .completedWithErrors, .preflightFailed: nil
        }
    }

    static func label(for status: StatusKind) -> LocalizedStringResource {
        switch status {
        case .waiting: .module("Waiting", comment: "Item status: queued, nothing has happened yet.")
        case .preparing: .module("Preparing…", comment: "Item status: getting ready to install.")
        case .downloading: .module("Downloading…", comment: "Item status: the download is running.")
        case .installing: .module("Installing…", comment: "Item status: the install is running.")
        case .running: .module("Running…", comment: "Item status: a script is running.")
        case .installed: .module("Installed", comment: "Item status: the app was installed.")
        case .done: .module("Done", comment: "Item status: finished successfully.")
        case .failed: .module("Failed", comment: "Item status: did not succeed.")
        case .skipped: .module("Skipped", comment: "Item status: deliberately not done.")
        case .notNeeded: .module("Not needed", comment: "Item status: already in the desired state, so nothing was done.")
        case .downloadFailed: .module("Download failed", comment: "Item status: the download did not complete.")
        case .hashMismatch: .module("Verification failed", comment: "Item status: the downloaded file did not match its expected checksum.")
        case .timedOut: .module("Timed out", comment: "Item status: took longer than allowed and was given up on.")
        case .awaitingUser: .module("Waiting for you", comment: "Item status: the person at the Mac has to do something before this can finish.")
        }
    }
}

import Foundation
import OnboardCore
import os

/// Reads what provisioning has to say to the user logging in, and records
/// that they have been told.
///
/// Both halves live here because both are needed before the first frame —
/// the app has to decide whether to open a window at all (`AppDelegate`) and
/// then which stage to show (`RootView`) — and the XPC answer arrives far
/// too late for either.
enum ProvisioningState {
    /// Read from the daemon's progress file, which is world-readable.
    /// Device state itself is root-only, so this is the only view of the
    /// run a user-session app has at launch.
    ///
    /// The per-item outcomes and the engine state together, deliberately.
    /// The daemon publishes `waitingForConfig` at the top of every run, so
    /// after a reboot the file says "waiting" for as long as the run takes
    /// while still carrying the failed records underneath — reading either
    /// one alone got this wrong on hardware, in opposite directions.
    static func news(configuration: Configuration?) -> ProvisioningNews {
        // Ask the system directly rather than trusting the snapshot for this
        // one answer. progress.json is written by the daemon, and at login
        // the file on disk may predate the daemon that would have flagged the
        // Mac — which is exactly how an ineligible VM reached onboarding
        // even with the flag already implemented. Eligibility is cheap to
        // establish and must not depend on who wrote the file last.
        if EnrollmentCheck.isIneligible(configuration: configuration) {
            return .ineligible
        }
        return ProvisioningNews(
            snapshot: ProgressSnapshot.read(from: StateStore().progressFileURL),
            dismissedRunAt: (try? StateStore.forCurrentUser().loadUserState())?.dismissedProvisioningRunAt
        )
    }

    /// Records that this user has seen the current run's verdict, so the
    /// next login is not interrupted by the same news. Only a newer failed
    /// run brings the card back.
    /// Never called for an ineligible Mac: there is nothing to acknowledge,
    /// and recording a dismissal would let the next login fall through to
    /// onboarding on a Mac the profile refused.
    static func rememberDismissal() {
        guard let startedAt = ProgressSnapshot.read(from: StateStore().progressFileURL)?.startedAt else {
            return
        }
        let store = StateStore.forCurrentUser()
        var state = (try? store.loadUserState()) ?? UserState()
        state.dismissedProvisioningRunAt = startedAt
        do {
            try store.saveUserState(state)
            OnboardLog.app.notice("recorded this user's dismissal of the failed provisioning run")
        } catch {
            // Worst case the card shows once more at the next login.
            OnboardLog.app.error("could not record the dismissal: \(error.localizedDescription, privacy: .public)")
        }
    }
}

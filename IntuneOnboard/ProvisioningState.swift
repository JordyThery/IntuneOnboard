import Foundation
import OnboardCore
import os

/// Provisioning status as seen from a user session at launch, before XPC is
/// available.
enum ProvisioningState {
    /// Read from the daemon's world-readable progress file. Eligibility is
    /// checked directly, because the file may predate the current daemon.
    static func news(configuration: Configuration?) -> ProvisioningNews {
        if EnrollmentCheck.isIneligible(configuration: configuration) {
            return .ineligible
        }
        return ProvisioningNews(
            snapshot: ProgressSnapshot.read(from: StateStore().progressFileURL),
            dismissedRunAt: (try? StateStore.forCurrentUser().loadUserState())?.dismissedProvisioningRunAt
        )
    }

    /// Records that this user has dismissed the current run's failure. A
    /// later failed run shows it again. Not used on ineligible Macs.
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
            OnboardLog.app.error("could not record the dismissal: \(error.localizedDescription, privacy: .public)")
        }
    }
}

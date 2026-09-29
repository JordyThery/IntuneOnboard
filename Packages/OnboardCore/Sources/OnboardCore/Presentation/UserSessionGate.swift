import Foundation

/// What provisioning has to tell the user at login, from the daemon's
/// progress and what the user has already dismissed.
public enum ProvisioningNews: Equatable, Sendable {
    /// Completed, or its failure was already shown to this user.
    case nothing
    /// Still running.
    case inProgress
    /// Failed, and not yet shown to this user.
    case unseenFailure
    /// `requireADE` is set and the Mac was not enrolled through ADE. Neither
    /// stage runs and nothing is shown; the administrator sees exit code 12
    /// and `not applicable (requireADE)` in the custom attribute.
    case ineligible

    /// - Parameters:
    ///   - snapshot: the daemon's last progress; nil if it has not published
    ///     yet, which is treated as in progress.
    ///   - dismissedRunAt: `UserState.dismissedProvisioningRunAt`.
    public init(snapshot: ProgressSnapshot?, dismissedRunAt: Date?) {
        guard let snapshot else {
            self = .inProgress
            return
        }
        if snapshot.ineligible {
            self = .ineligible
            return
        }
        switch snapshot.engineState {
        case .waitingForConfig, .preflight, .running:
            self = .inProgress
        case .completed:
            self = .nothing
        case .completedWithErrors, .preflightFailed:
            // Preflight failures count too, though no item failed.
            guard let dismissedRunAt, let startedAt = snapshot.startedAt else {
                self = .unseenFailure
                return
            }
            self = startedAt > dismissedRunAt ? .unseenFailure : .nothing
        }
    }
}

/// Whether the app shows a window at login. The agent starts it at every
/// login. Outstanding onboarding always shows; provisioning shows only when it
/// has something new to report.
public enum UserSessionGate {
    /// - Parameters:
    ///   - deviceCompleted: the completion marker exists.
    ///   - hasOutstandingUserWork: onboarding steps remain.
    ///   - provisioning: what provisioning has to tell this user.
    public static func shouldPresent(
        deviceCompleted: Bool,
        hasOutstandingUserWork: Bool = false,
        provisioning: ProvisioningNews
    ) -> Bool {
        // An ineligible Mac shows nothing, even with onboarding configured.
        if provisioning == .ineligible { return false }
        if hasOutstandingUserWork { return true }
        if deviceCompleted { return false }
        // Not completed, but a dismissed failure has nothing new to show.
        return provisioning != .nothing
    }
}

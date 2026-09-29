import Foundation

/// What provisioning has to say to the person logging in.
///
/// Derived from the daemon's published progress plus what this user has
/// already been shown, so "the device is not provisioned" and "the device
/// has something to tell you" stop being the same question. They came apart
/// the moment a failure could be permanent: a Mac with an item that will
/// never succeed never gets its completion marker, and keying the whole
/// user-session UI on that marker meant the app launched at every login for
/// the life of the Mac.
public enum ProvisioningNews: Equatable, Sendable {
    /// Finished cleanly, or its failure has already been shown to this user.
    case nothing
    /// Still working — worth a "please wait".
    case inProgress
    /// Failed, and this user has not yet seen this run's verdict.
    case unseenFailure
    /// This Mac may not be configured at all: `requireADE` is set and it was
    /// not enrolled through Automated Device Enrollment.
    ///
    /// Neither stage runs, and nothing is shown. "Setup can't start on this
    /// Mac" is the right thing to say when a Mac was in scope and something
    /// went wrong; this Mac was never in scope. Its owner cannot
    /// retroactively ADE-enrol it, so a window they cannot act on is pure
    /// alarm. The administrator hears about it through exit code 12, the
    /// log, and `provisioning: not applicable (requireADE)` in the Intune
    /// attribute.
    case ineligible

    /// - Parameters:
    ///   - snapshot: the daemon's last published progress; nil when it has
    ///     not published at all yet, which is itself a reason to show the
    ///     card — it says "connecting" while the daemon starts.
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
            // A preflight failure counts even though it leaves no failed
            // item behind: there is nothing on disk to point at, but the
            // Mac is just as unprovisioned and the user just as entitled
            // to be told once.
            guard let dismissedRunAt, let startedAt = snapshot.startedAt else {
                self = .unseenFailure
                return
            }
            self = startedAt > dismissedRunAt ? .unseenFailure : .nothing
        }
    }
}

/// Decides whether the user-session UI has anything to say at login.
///
/// The `user`-mode LaunchAgent is `RunAtLoad`, so the app starts at every
/// login. Provisioning's card is a *device* progress screen: once there is
/// nothing left to report there is nothing for the person at the keyboard to
/// do with it, and showing it on a Mac that has been like this for weeks is
/// noise.
///
/// Onboarding (M4) is what user space is really for, and it overrides all of
/// this: a user with outstanding onboarding items has something to see
/// whatever the device state says.
public enum UserSessionGate {
    /// - Parameters:
    ///   - deviceCompleted: the device marker exists. Only written when no
    ///     required item failed, so a failed run leaves this false.
    ///   - hasOutstandingUserWork: the onboarding stage has steps left.
    ///   - provisioning: what provisioning has to say to *this* user.
    public static func shouldPresent(
        deviceCompleted: Bool,
        hasOutstandingUserWork: Bool = false,
        provisioning: ProvisioningNews
    ) -> Bool {
        // Out of scope outranks everything, including outstanding
        // onboarding: this Mac is not to be configured, and saying so to
        // the person at the keyboard helps nobody.
        if provisioning == .ineligible { return false }
        if hasOutstandingUserWork { return true }
        if deviceCompleted { return false }
        // Unprovisioned, but that alone is not a reason to open a window:
        // a failure this user has already waved past has nothing new to
        // say, and onboarding is finished, so there is nothing to show.
        return provisioning != .nothing
    }
}

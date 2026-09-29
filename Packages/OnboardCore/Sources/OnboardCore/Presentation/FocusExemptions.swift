import Foundation

/// The apps onboarding itself sent the user to. `windowPosition: focus`
/// lifts its backdrop while one of these is frontmost — an `open` step that
/// launches Company Portal would otherwise strand it behind the backdrop —
/// and restores the backdrop the moment anything else comes forward, so a
/// browser started from the Dock is still covered.
///
/// Membership, not step state, is the rule. The first attempt lifted while an
/// `open` step was "waiting on the user", which never fired: launching
/// successfully writes a success record, and derivation reads that as
/// completed the same instant, so the step was never in the waiting state
/// the backdrop was watching for.
@MainActor
public enum FocusExemptions {
    public private(set) static var bundleIDs: Set<String> = []

    /// Called when the onboarding launches something on the user's behalf.
    public static func allow(_ bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        bundleIDs.insert(bundleID)
    }

    public static func removeAll() {
        bundleIDs.removeAll()
    }

    /// Whether the backdrop should lift for the app that just came forward.
    /// Our own bundle id is never exempt, which is what brings the backdrop
    /// back when the user returns to the onboarding card.
    public static func allowsBackdropLift(
        for bundleID: String?,
        in exemptions: Set<String>? = nil
    ) -> Bool {
        guard let bundleID else { return false }
        return (exemptions ?? bundleIDs).contains(bundleID)
    }
}

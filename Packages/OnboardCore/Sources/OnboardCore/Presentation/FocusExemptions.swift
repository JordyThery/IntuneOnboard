import Foundation

/// Apps opened by onboarding. With `windowPosition: focus`, the backdrop is
/// lifted while one of them is frontmost and restored when any other app is.
@MainActor
public enum FocusExemptions {
    public private(set) static var bundleIDs: Set<String> = []

    /// Records an app that onboarding opened.
    public static func allow(_ bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        bundleIDs.insert(bundleID)
    }

    public static func removeAll() {
        bundleIDs.removeAll()
    }

    /// Whether to lift the backdrop for the frontmost app. Never true for
    /// this app itself.
    public static func allowsBackdropLift(
        for bundleID: String?,
        in exemptions: Set<String>? = nil
    ) -> Bool {
        guard let bundleID else { return false }
        return (exemptions ?? bundleIDs).contains(bundleID)
    }
}

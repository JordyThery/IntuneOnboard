import Foundation
import OnboardCore

/// The mechanism for putting the UI in front of someone is swappable per
/// launch mode (spec §2): Setup Assistant now, login window / user session
/// arriving with M3.
@MainActor
protocol AppLaunching {
    /// Launch the UI into the given session; returns true when the launch
    /// command was issued successfully.
    @discardableResult
    func launchApp(uid: uid_t) -> Bool
}

import Foundation
import OnboardCore

/// Launches the UI into a user session.
@MainActor
protocol AppLaunching {
    /// Returns true when the launch command was issued.
    @discardableResult
    func launchApp(uid: uid_t) -> Bool
}

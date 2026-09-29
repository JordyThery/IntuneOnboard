import AppKit
import OnboardCore
import OnboardUI
import os

/// Keeps the kiosk launch modes on screen. The first hardware run showed ⌘Q
/// dismissing the window over Setup Assistant while the daemon carried on
/// working — from the user's side, onboarding had silently vanished. In
/// `setup-assistant` the app now only exits when it decides
/// to, via `AppTermination`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The user-mode LaunchAgent is `RunAtLoad`, so this app starts at every
    /// login. Decide here whether it has anything to say — before the window
    /// is ordered front, so a Mac with nothing to show never flashes one.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard case .user = LaunchArguments.current.mode else { return }

        let configuration = try? ConfigLoader.load()
        let deviceCompleted = (try? StateStore().loadDeviceState())?.completedAt != nil
        let outstanding = LiveOnboarding.hasOutstandingWork(configuration: configuration)
        guard !UserSessionGate.shouldPresent(
            deviceCompleted: deviceCompleted,
            hasOutstandingUserWork: outstanding,
            provisioning: ProvisioningState.news(configuration: configuration)
        ) else { return }

        // Say which of the two silences this is. "Finished" is wrong for an
        // out-of-scope Mac, and this line is the diagnostic that explains an
        // app which deliberately shows nothing.
        if ProvisioningState.news(configuration: configuration) == .ineligible {
            OnboardLog.app.notice("this Mac is out of scope (requireADE) — nothing to show in this user session")
        } else {
            OnboardLog.app.notice("provisioning is finished — nothing to show in this user session")
        }
        exit(EXIT_SUCCESS)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppTermination.isAuthorized else { return .terminateNow }
        let mode = LaunchArguments.current.mode
        if mode.isKiosk {
            OnboardLog.app.notice("termination refused in \(mode.description, privacy: .public) mode")
            return .terminateCancel
        }
        // onboarding.allowQuit: false — the user leaves via Done (or an
        // administrator via ⌃⌥⌘Q); both go through AppTermination.
        if case .user = mode, (try? ConfigLoader.load())?.onboarding?.allowQuit == false {
            OnboardLog.app.notice("termination refused: the onboarding profile sets allowQuit false")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// The only sanctioned way out. Everything else — ⌘Q, the menu item, an
/// AppleScript `quit` — is refused in the kiosk modes.
@MainActor
enum AppTermination {
    private(set) static var isAuthorized = false

    static func requestExit(reason: String) {
        isAuthorized = true
        OnboardLog.app.notice("exiting: \(reason, privacy: .public)")
        NSApp.terminate(nil)
    }
}

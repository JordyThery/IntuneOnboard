import AppKit
import OnboardCore
import OnboardUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The agent launches the app at every login. Exits before any window
    /// appears when there is nothing to show.
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

        if ProvisioningState.news(configuration: configuration) == .ineligible {
            OnboardLog.app.notice("this Mac is out of scope (requireADE) — nothing to show in this user session")
        } else {
            OnboardLog.app.notice("provisioning is finished — nothing to show in this user session")
        }
        exit(EXIT_SUCCESS)
    }

    /// Termination is refused in kiosk mode and under `allowQuit: false`,
    /// unless requested through `AppTermination`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppTermination.isAuthorized else { return .terminateNow }
        let mode = LaunchArguments.current.mode
        if mode.isKiosk {
            OnboardLog.app.notice("termination refused in \(mode.description, privacy: .public) mode")
            return .terminateCancel
        }
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

/// The only way the app quits itself.
@MainActor
enum AppTermination {
    private(set) static var isAuthorized = false

    static func requestExit(reason: String) {
        isAuthorized = true
        OnboardLog.app.notice("exiting: \(reason, privacy: .public)")
        NSApp.terminate(nil)
    }
}

import Foundation
import OnboardCore
import os

/// Watches the console user and reacts to session changes: logs every
/// transition, launches the UI into the Setup Assistant session, and puts it
/// back if it disappears while there is still work to show. Polling (2 s) is
/// good enough; SCDynamicStore notifications can replace it if the hardware
/// runs show a need.
@MainActor
final class SessionMonitor {
    private let launcher: any AppLaunching
    private let appExecutablePath: String
    /// The daemon stops relaunching the UI once the run is over — otherwise it
    /// would fight the app's own exit-on-completion.
    private let isRunActive: @Sendable () async -> Bool

    private var lastLogged: ConsoleUser?
    private var launchedSetupAssistantUI = false
    private var task: Task<Void, Never>?
    /// Caps relaunches so the kiosk can never trap the Mac, even when XPC is
    /// down and the app's polite "stop" can't reach us.
    private var relaunchPolicy = RelaunchPolicy()

    init(
        launcher: any AppLaunching,
        appExecutablePath: String = SetupAssistantLauncher.appExecutableURL().path,
        isRunActive: @escaping @Sendable () async -> Bool
    ) {
        self.launcher = launcher
        self.appExecutablePath = appExecutablePath
        self.isRunActive = isRunActive
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll() async {
        let user = ConsoleUser.current()

        if user != lastLogged {
            if let user {
                OnboardLog.daemon.notice("console user: \(user.name, privacy: .public) uid=\(user.uid)")
            } else {
                OnboardLog.daemon.notice("console user: none")
            }
            lastLogged = user
        }

        guard let user, user.isSetupAssistant else { return }

        // Nothing to show once the run is over. This gate also covers the
        // *first* launch, because launchd re-spawns us on demand and a fresh
        // instance has `launchedSetupAssistantUI == false`: on a finished
        // device it would put the kiosk back up, the app would read
        // "completed" and exit 5 s later, and its polling would spawn us
        // again — the window closing, reappearing and closing again that the
        // first accepted run showed during Setup Assistant.
        guard await isRunActive() else { return }

        if !launchedSetupAssistantUI {
            launchedSetupAssistantUI = launcher.launchApp(uid: user.uid)
            return
        }

        // Force-quit and crashes can still take the window away mid-run, so
        // put it back — but only a few times (⌃⌥⌘Q must always win).
        guard relaunchPolicy.canRelaunch else { return }
        guard !AppPresence.isAppRunning(uid: user.uid, executablePath: appExecutablePath) else { return }

        relaunchPolicy.recordRelaunch()
        OnboardLog.launch.notice("""
        provisioning UI is gone while the run is active — relaunching \
        (\(self.relaunchPolicy.relaunchCount)/\(self.relaunchPolicy.limit))
        """)
        launcher.launchApp(uid: user.uid)

        if relaunchPolicy.isExhausted {
            OnboardLog.launch.warning("""
            relaunch limit reached — the provisioning UI will not be restored again \
            this run. Provisioning itself continues; check the log for why the app \
            keeps exiting.
            """)
        }
    }
}

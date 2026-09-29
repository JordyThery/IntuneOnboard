import Foundation
import OnboardCore
import os

/// Polls the console user every two seconds, launches the UI into the Setup
/// Assistant session, and relaunches it if it exits while provisioning runs.
@MainActor
final class SessionMonitor {
    private let launcher: any AppLaunching
    private let appExecutablePath: String
    private let isRunActive: @Sendable () async -> Bool

    private var lastLogged: ConsoleUser?
    private var launchedSetupAssistantUI = false
    private var task: Task<Void, Never>?
    /// Caps relaunches, so the window can always be dismissed.
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

        // Also gates the first launch, since each daemon instance starts with
        // `launchedSetupAssistantUI == false`.
        guard await isRunActive() else { return }

        if !launchedSetupAssistantUI {
            launchedSetupAssistantUI = launcher.launchApp(uid: user.uid)
            return
        }

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

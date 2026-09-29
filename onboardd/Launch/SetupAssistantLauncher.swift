import Foundation
import OnboardCore
import os

/// Launches the app into a session with `launchctl asuser <uid> open -a …`.
@MainActor
struct SetupAssistantLauncher: AppLaunching {
    @discardableResult
    func launchApp(uid: uid_t) -> Bool {
        let appURL = Self.appBundleURL()
        OnboardLog.launch.notice("""
        launching \(appURL.path, privacy: .public) into uid \(uid) \
        via launchctl asuser + open
        """)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = [
            "asuser", String(uid),
            "/usr/bin/open", "-a", appURL.path,
            "--args", "--mode", "setup-assistant", "--launched-by", "daemon-asuser-open",
        ]
        do {
            try process.run()
            return true
        } catch {
            OnboardLog.launch.error("failed to launch app: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The bundle containing this executable (`Contents/MacOS/onboardd`), or
    /// the installed path when run from elsewhere.
    nonisolated static func appBundleURL() -> URL {
        let executable = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Intune Onboard.app
        if candidate.pathExtension == "app" {
            return candidate
        }
        return URL(filePath: ServiceIdentity.installedAppPath)
    }

    /// The app's executable, read from its Info.plist.
    nonisolated static func appExecutableURL() -> URL {
        let bundle = appBundleURL()
        let name = Bundle(url: bundle)?.infoDictionary?["CFBundleExecutable"] as? String
        return bundle.appending(path: "Contents/MacOS/\(name ?? "Intune Onboard")")
    }
}

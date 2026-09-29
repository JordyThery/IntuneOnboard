import Foundation
import OnboardCore
import os

/// Is the UI still on screen in a given session? The provisioning window is a
/// kiosk, but it can still be killed (⌘Q before M3, force-quit or a crash
/// after), and a vanished window looks to the user like onboarding stopped.
enum AppPresence {
    /// `pgrep -U <uid> -f <executable>`: the daemon runs as root and sees every
    /// process, and the `-U` filter keeps the daemon's own path — which lives
    /// inside the same bundle — from matching itself.
    static func isAppRunning(uid: uid_t, executablePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-U", String(uid), "-f", executablePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Without an answer, assume it is running: a wrong "no" would
            // relaunch the app on top of itself every poll.
            OnboardLog.launch.error("pgrep failed: \(error.localizedDescription, privacy: .public)")
            return true
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

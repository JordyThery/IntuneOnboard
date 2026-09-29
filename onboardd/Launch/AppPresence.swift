import Foundation
import OnboardCore
import os

/// Is the UI still on screen in a given session? The provisioning window is a
/// kiosk, but it can still be killed (⌘Q before M3, force-quit or a crash
/// after), and a vanished window looks to the user like onboarding stopped.
enum AppPresence {
    /// `pgrep -U <uid> -f <pattern>`: the daemon runs as root and sees every
    /// process, and the `-U` filter keeps the daemon's own path — which lives
    /// inside the same bundle — from matching itself.
    ///
    /// `-f` takes a *regex* matched anywhere in the command line, and an app
    /// path is full of regex metacharacters (`.app`) — unescaped, any command
    /// line those happened to match reported the app as running, which
    /// suppressed the relaunch. Escaped and anchored: the command line must
    /// *be* the path, optionally followed by arguments.
    static func isAppRunning(uid: uid_t, executablePath: String) -> Bool {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: executablePath) + "( |$)"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-U", String(uid), "-f", pattern]
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

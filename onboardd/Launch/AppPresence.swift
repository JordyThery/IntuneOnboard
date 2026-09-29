import Foundation
import OnboardCore
import os

/// Whether the UI is running in a given session.
enum AppPresence {
    /// Matches the app's command line exactly: `-f` takes a regex, so the path
    /// is escaped and anchored. `-U` excludes the daemon, which lives in the
    /// same bundle.
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
            // Assume running, so a failed check never relaunches a running app.
            OnboardLog.launch.error("pgrep failed: \(error.localizedDescription, privacy: .public)")
            return true
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

import Foundation

/// Whether the Mac was enrolled through Automated Device Enrollment.
/// Synchronous, for callers that need the answer before showing anything.
/// `Preflight` has an injectable async equivalent.
public enum EnrollmentCheck {
    /// Treats a failed query as enrolled; the daemon's preflight makes the
    /// definitive check.
    public static func isADEEnrolled() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/profiles")
        process.arguments = ["status", "-type", "enrollment"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            OnboardLog.app.error("could not ask profiles about enrollment: \(error.localizedDescription, privacy: .public)")
            return true
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return true }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { line in
                let normalized = line.lowercased()
                return normalized.contains("enrolled via dep") && normalized.contains("yes")
            }
    }

    /// True when `requireADE` is set and the Mac was not enrolled through ADE.
    public static func isIneligible(configuration: Configuration?) -> Bool {
        configuration?.requireADE == true && !isADEEnrolled()
    }
}

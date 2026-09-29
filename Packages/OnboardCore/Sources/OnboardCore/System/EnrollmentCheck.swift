import Foundation

/// Is this Mac enrolled through Automated Device Enrollment?
///
/// Synchronous, because both callers need the answer before they can decide
/// anything: the user-session app before its first frame, and `status`
/// before it prints its single line. `profiles` returns in well under a
/// second, and neither caller reaches here unless the profile sets
/// `requireADE`.
///
/// `Preflight` keeps its own async version — that one is injectable so the
/// engine's tests can drive both answers without a subprocess.
public enum EnrollmentCheck {
    /// Any failure to ask counts as **enrolled**. Refusing a Mac because a
    /// subprocess misbehaved would strand a legitimate one, and the daemon
    /// still makes the authoritative check before provisioning anything.
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

    /// True when the profile asks for ADE and this Mac was not enrolled that
    /// way — the configuration does not apply here at all.
    public static func isIneligible(configuration: Configuration?) -> Bool {
        configuration?.requireADE == true && !isADEEnrolled()
    }
}

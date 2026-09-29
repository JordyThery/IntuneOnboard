/// Process exit codes. Stable and documented, so a monitoring script can
/// key off them.
public enum ExitCode: Int32, Sendable {
    case success = 0
    case notRoot = 10
    case userSessionTimeout = 11
    case notADE = 12
    case networkPreflightFailed = 13
    case installomatorMissing = 20
    case installomatorIntegrityFailed = 21
    case installomatorUpdateFailed = 22
    case installomatorDebugUnverifiable = 23
    case completedWithErrors = 30
}

/// Process exit codes.
public enum ExitCode: Int32, Sendable {
    case success = 0
    case notRoot = 10
    case notADE = 12
    case networkPreflightFailed = 13
    case completedWithErrors = 30
}

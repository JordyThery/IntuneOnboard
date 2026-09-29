import os

/// Loggers for the daemon and the app.
public enum OnboardLog {
    public static let subsystem = "be.jordythery.intuneonboard"

    public static let daemon = Logger(subsystem: subsystem, category: "daemon")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let launch = Logger(subsystem: subsystem, category: "launch")
}

import os

/// Central logging namespace, shared by the daemon and the app.
/// Categories separate the components; file mirroring (rotating sink under
/// /var/log/IntuneOnboard) arrives in M1.
public enum OnboardLog {
    public static let subsystem = "be.jordythery.intuneonboard"

    public static let daemon = Logger(subsystem: subsystem, category: "daemon")
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let launch = Logger(subsystem: subsystem, category: "launch")
}

/// Shared identifiers for the daemon, the agents and the app.
public enum ServiceIdentity {
    public static let bundleIdentifier = "be.jordythery.intuneonboard"

    /// The daemon's *code-signing* identifier. A command-line tool has no
    /// Info.plist, so this is not inferred from a build setting — build-pkg.sh
    /// passes it to `codesign --identifier`, and the XPC requirement names it
    /// explicitly. Change one and you must change the other.
    public static let daemonSigningIdentifier = "be.jordythery.intuneonboard.daemon"
    public static let daemonLabel = "be.jordythery.intuneonboard.daemon"
    public static let agentLabel = "be.jordythery.intuneonboard.agent"

    /// Mach service name published by the daemon's XPC listener (wired up in M2).
    public static let machServiceName = "be.jordythery.intuneonboard.xpc"

    /// Where the pkg installs the app.
    public static let installedAppPath = "/Applications/Utilities/Intune Onboard.app"

    /// Managed preferences domain; config is read only from /Library/Managed Preferences.
    public static let preferencesDomain = "be.jordythery.intuneonboard"
}

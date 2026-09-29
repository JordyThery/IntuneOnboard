/// Identifiers shared by the daemon, agent and app.
public enum ServiceIdentity {
    public static let bundleIdentifier = "be.jordythery.intuneonboard"

    /// The daemon's code-signing identifier. Set by build-pkg.sh with
    /// `codesign --identifier` and required by the XPC check; keep both in step.
    public static let daemonSigningIdentifier = "be.jordythery.intuneonboard.daemon"
    public static let daemonLabel = "be.jordythery.intuneonboard.daemon"
    public static let agentLabel = "be.jordythery.intuneonboard.agent"

    /// The daemon's Mach service.
    public static let machServiceName = "be.jordythery.intuneonboard.xpc"

    /// Where the package installs the app.
    public static let installedAppPath = "/Applications/Utilities/Intune Onboard.app"

    /// Preference domain, read only from /Library/Managed Preferences.
    public static let preferencesDomain = "be.jordythery.intuneonboard"
}

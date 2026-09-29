import Foundation

/// Installomator option handling. Because Installomator `eval`s every
/// `KEY=value` argument, options are allowlisted by shape, `DEBUG=` is never
/// accepted from config, and `DEBUG=0` is always appended last so no earlier
/// option can re-enable dry-run mode (last assignment wins).
public enum InstallomatorOptions {
    /// Options suited to unattended bootstrap — silent, non-blocking,
    /// forced — the default `defaultOptions`.
    public static let bootstrapDefaults = [
        "NOTIFY=silent",
        "BLOCKING_PROCESS_ACTION=ignore",
        "INSTALL=force",
        "IGNORE_APP_STORE_APPS=yes",
        "LOGGING=REQ",
    ]

    /// Nil when the option is acceptable, otherwise the reason.
    public static func violation(of option: String) -> ConfigError.OptionViolation? {
        if option.hasPrefix("DEBUG=") || option == "DEBUG" {
            return .debugForbidden
        }
        // Regex isn't Sendable, so the literal lives here rather than in a static.
        let allowedShape = /^[A-Z_]+=[A-Za-z0-9_.,:\/ @-]*$/
        guard option.wholeMatch(of: allowedShape) != nil else {
            return .disallowedShape
        }
        return nil
    }

    /// Item options are appended after the defaults (later assignments win in
    /// Installomator), and `DEBUG=0` is forced last.
    public static func effectiveArguments(defaults: [String], itemOptions: [String]) -> [String] {
        defaults + itemOptions + ["DEBUG=0"]
    }
}

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
    ///
    /// A bare value may not contain a space: Installomator's `eval` parses
    /// `KEY=a b` as the assignment `KEY=a` followed by the *command* `b`, so
    /// an unquoted space silently turned part of an option into code running
    /// as root. A value that needs spaces (a LOGO path, say) must arrive
    /// quoted — `LOGO="/Library/Application Support/x.png"` — which `eval`
    /// reads back as one assignment. The quoted form still excludes the
    /// characters that would end the quote or expand inside it.
    public static func violation(of option: String) -> ConfigError.OptionViolation? {
        if option.hasPrefix("DEBUG=") || option == "DEBUG" {
            return .debugForbidden
        }
        // Regexes aren't Sendable, so the literals live here rather than in statics.
        let bareShape = /^[A-Z_]+=[A-Za-z0-9_.,:\/@-]*$/
        let quotedShape = /^[A-Z_]+="[A-Za-z0-9_.,:\/@ -]*"$/
        guard option.wholeMatch(of: bareShape) != nil
                || option.wholeMatch(of: quotedShape) != nil else {
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

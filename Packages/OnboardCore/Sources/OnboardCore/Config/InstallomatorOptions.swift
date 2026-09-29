import Foundation

/// Installomator options. Installomator `eval`s each `KEY=value` argument, so
/// options are restricted by shape, `DEBUG` is rejected, and `DEBUG=0` is
/// appended last (the last assignment wins).
public enum InstallomatorOptions {
    /// Default `defaultOptions`: silent, non-blocking, forced.
    public static let bootstrapDefaults = [
        "NOTIFY=silent",
        "BLOCKING_PROCESS_ACTION=ignore",
        "INSTALL=force",
        "IGNORE_APP_STORE_APPS=yes",
        "LOGGING=REQ",
    ]

    /// nil if acceptable, otherwise the reason.
    ///
    /// Unquoted values may not contain spaces: `eval` would run the text after
    /// a space as a command. Values with spaces must be quoted, and quoted
    /// values may not contain characters that end or expand within the quote.
    public static func violation(of option: String) -> ConfigError.OptionViolation? {
        if option.hasPrefix("DEBUG=") || option == "DEBUG" {
            return .debugForbidden
        }
        // Regex literals are not Sendable, so they cannot be static.
        let bareShape = /^[A-Z_]+=[A-Za-z0-9_.,:\/@-]*$/
        let quotedShape = /^[A-Z_]+="[A-Za-z0-9_.,:\/@ -]*"$/
        guard option.wholeMatch(of: bareShape) != nil
                || option.wholeMatch(of: quotedShape) != nil else {
            return .disallowedShape
        }
        return nil
    }

    /// Defaults, then item options, then `DEBUG=0`.
    public static func effectiveArguments(defaults: [String], itemOptions: [String]) -> [String] {
        defaults + itemOptions + ["DEBUG=0"]
    }
}

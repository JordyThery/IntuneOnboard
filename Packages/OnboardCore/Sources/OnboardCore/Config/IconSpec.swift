import Foundation

/// An icon reference from config. The accepted sources:
/// - `symbol:<SF Symbol name>`
/// - `name:<named image>` (`name:NSComputer`, an asset name)
/// - an absolute path to an image or `.app`
/// - `bundleid:<id>` (uses that app's icon)
/// - an https URL (downloaded by the UI layer)
public enum IconSpec: Equatable, Sendable {
    case symbol(String)
    case named(String)
    case path(String)
    case bundleID(String)
    case remote(URL)

    /// Parses the config string form. Returns nil for unparseable or
    /// insecure (non-https URL, relative path) values.
    public init?(configString: String) {
        if let name = configString.removingPrefix("symbol:") {
            guard !name.isEmpty else { return nil }
            self = .symbol(name)
        } else if let name = configString.removingPrefix("name:") {
            guard !name.isEmpty else { return nil }
            self = .named(name)
        } else if let id = configString.removingPrefix("bundleid:") {
            guard !id.isEmpty else { return nil }
            self = .bundleID(id)
        } else if configString.hasPrefix("/") {
            self = .path(configString)
        } else if let url = URL(string: configString), url.scheme != nil {
            guard url.scheme == "https" else { return nil }
            self = .remote(url)
        } else {
            return nil
        }
    }
}

extension String {
    /// Returns the remainder after `prefix`, or nil when the prefix is absent.
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

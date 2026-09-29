import Foundation

/// An icon reference:
/// - `symbol:<SF Symbol>`
/// - `name:<asset>`, e.g. `name:NSComputer`
/// - an absolute path to an image or `.app`
/// - `bundleid:<id>`
/// - an `https` URL
public enum IconSpec: Equatable, Sendable {
    case symbol(String)
    case named(String)
    case path(String)
    case bundleID(String)
    case remote(URL)

    /// nil for unparseable values, non-https URLs and relative paths.
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
    /// The remainder after `prefix`, or nil.
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

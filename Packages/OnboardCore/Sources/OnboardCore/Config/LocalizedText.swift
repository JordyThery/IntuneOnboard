import Foundation

/// A user-facing string from config: either a plain string or a dictionary of
/// language code → string. Resolution: exact tag → base language
/// (`nl-BE` → `nl`) → `en` → first key (sorted, for determinism).
public struct LocalizedText: Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case plain(String)
        case localized([String: String])
    }

    public let storage: Storage

    public init(plain: String) {
        self.storage = .plain(plain)
    }

    public init(localized: [String: String]) {
        self.storage = .localized(localized)
    }

    /// Parses the plist value: String or [String: String]. Returns nil for
    /// anything else (the caller reports a typed error with the key path).
    public init?(plistValue: Any) {
        if let string = plistValue as? String {
            self.storage = .plain(string)
        } else if let dict = plistValue as? [String: String], !dict.isEmpty {
            self.storage = .localized(dict)
        } else {
            return nil
        }
    }

    /// Resolves against a preference list such as `Locale.preferredLanguages`.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch storage {
        case .plain(let value):
            return value
        case .localized(let table):
            for tag in preferredLanguages {
                if let exact = table[tag] {
                    return exact
                }
                let base = String(tag.prefix(while: { $0 != "-" && $0 != "_" }))
                if let baseMatch = table[base] {
                    return baseMatch
                }
            }
            if let english = table["en"] {
                return english
            }
            // Deterministic last resort.
            return table.sorted(by: { $0.key < $1.key }).first?.value ?? ""
        }
    }
}

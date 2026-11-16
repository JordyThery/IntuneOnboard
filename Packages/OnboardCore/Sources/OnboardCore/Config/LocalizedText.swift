import Foundation

/// A string, or a dictionary of language code to string. Resolved as exact
/// tag, then shorter tags (`nl-BE` → `nl`), then another region of the same
/// language and script (`sv` → `sv-SE`, never `zh-Hant` → `zh-Hans`), then
/// `en`, then the first key. Tags compare case-insensitively, with `_` and
/// `-` alike.
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

    /// Accepts a String or [String: String]; nil otherwise.
    public init?(plistValue: Any) {
        if let string = plistValue as? String {
            self.storage = .plain(string)
        } else if let dict = plistValue as? [String: String], !dict.isEmpty {
            self.storage = .localized(dict)
        } else {
            return nil
        }
    }

    /// Resolves against a list such as `Locale.preferredLanguages`.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch storage {
        case .plain(let value):
            return value
        case .localized(let table):
            // Profiles are hand-written: accept `sv_SE`, `sv-SE` and `SV`
            // alike, and a regional key (`sv-SE`) for a bare `sv`.
            let normalized = Dictionary(
                table.map { (Self.normalize($0.key), $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            for tag in preferredLanguages.map(Self.normalize) {
                // `zh-hans-cn` → `zh-hans` → `zh`.
                var candidate = tag
                while true {
                    if let match = normalized[candidate] {
                        return match
                    }
                    guard let dash = candidate.lastIndex(of: "-") else { break }
                    candidate = String(candidate[..<dash])
                }
                let base = Self.baseLanguage(of: tag)
                let script = Self.script(of: tag)
                // Another region of the same language, in sorted order. A
                // different script is a different written language
                // (`zh-Hant` must not get `zh-Hans`), so it falls through.
                if let regional = normalized
                    .filter({ entry in
                        guard Self.baseLanguage(of: entry.key) == base else { return false }
                        guard let script, let keyScript = Self.script(of: entry.key) else { return true }
                        return keyScript == script
                    })
                    .sorted(by: { $0.key < $1.key })
                    .first {
                    return regional.value
                }
            }
            if let english = normalized["en"] {
                return english
            }
            // First key in sorted order, for a stable result.
            return table.sorted(by: { $0.key < $1.key }).first?.value ?? ""
        }
    }

    /// `sv_SE` → `sv-se`.
    private static func normalize(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// `sv-se` → `sv`.
    private static func baseLanguage(of tag: String) -> String {
        String(tag.prefix(while: { $0 != "-" }))
    }

    /// `zh-hant-tw` → `hant`; nil without a script subtag (`sv-se`).
    private static func script(of tag: String) -> String? {
        let subtags = tag.split(separator: "-")
        guard subtags.count > 1, subtags[1].count == 4, subtags[1].allSatisfy(\.isLetter) else { return nil }
        return String(subtags[1])
    }
}

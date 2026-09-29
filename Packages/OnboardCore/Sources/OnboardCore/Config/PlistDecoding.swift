import Foundation

/// A tiny hand-rolled decoder over `[String: Any]` plist content.
/// Chosen over Codable so every error carries the exact key path and the
/// LocalizedText/IconSpec "string or dict" shapes stay simple.
struct PlistDecoder {
    let dictionary: [String: Any]
    let path: String
    private(set) var errors: ErrorCollector

    final class ErrorCollector {
        private(set) var errors: [ConfigError] = []
        func add(_ error: ConfigError) { errors.append(error) }

        /// The unknown-key ledger: which keys each node holds, and which of
        /// them a decoder actually consumed. A key nobody reads is silently
        /// inert — a misspelling, or a leftover from an older schema — and
        /// silence is exactly the failure an admin cannot see.
        private var keysPresent: [String: Set<String>] = [:]
        private var keysRead: [String: Set<String>] = [:]

        func noteNode(path: String, keys: some Sequence<String>) {
            keysPresent[path, default: []].formUnion(keys)
        }

        func noteRead(path: String, key: String) {
            keysRead[path, default: []].insert(key)
        }

        /// One error per present-but-never-read key, in stable path order.
        /// `Payload*` at the root is exempt: that is Apple's profile-metadata
        /// namespace, and refusing to run because the MDM transport left a
        /// PayloadUUID behind would fail every Mac in a fleet over a key no
        /// admin wrote. Only at the root — nested, it is a typo like any
        /// other.
        var unknownKeyErrors: [ConfigError] {
            keysPresent
                .flatMap { path, present in
                    present.subtracting(keysRead[path] ?? []).compactMap { key -> ConfigError? in
                        if path == "config", key.hasPrefix("Payload") { return nil }
                        return ConfigError(path: "\(path).\(key)", kind: .unknownKey)
                    }
                }
                .sorted { $0.path < $1.path }
        }
    }

    init(dictionary: [String: Any], path: String, errors: ErrorCollector) {
        self.dictionary = dictionary
        self.path = path
        self.errors = errors
        errors.noteNode(path: path, keys: dictionary.keys)
    }

    /// Key presence, counted as a read: asking is consuming, as far as the
    /// unknown-key audit cares.
    func has(_ key: String) -> Bool {
        errors.noteRead(path: path, key: key)
        return dictionary[key] != nil
    }

    func child(_ key: String) -> PlistDecoder? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        guard let dict = raw as? [String: Any] else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: "dictionary")))
            return nil
        }
        return PlistDecoder(dictionary: dict, path: "\(path).\(key)", errors: errors)
    }

    func childArray(_ key: String) -> [PlistDecoder] {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return [] }
        guard let array = raw as? [[String: Any]] else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: "array of dictionaries")))
            return []
        }
        return array.enumerated().map { index, dict in
            PlistDecoder(dictionary: dict, path: "\(path).\(key)[\(index)]", errors: errors)
        }
    }

    /// Optional typed value; records a type error when present but wrong.
    func value<T>(_ key: String, as type: T.Type, expected: String) -> T? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        guard let typed = raw as? T else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: expected)))
            return nil
        }
        return typed
    }

    func string(_ key: String) -> String? { value(key, as: String.self, expected: "string") }
    func int(_ key: String) -> Int? { value(key, as: Int.self, expected: "integer") }
    func bool(_ key: String) -> Bool? { value(key, as: Bool.self, expected: "boolean") }
    func stringArray(_ key: String) -> [String]? { value(key, as: [String].self, expected: "array of strings") }
    func stringDict(_ key: String) -> [String: String]? { value(key, as: [String: String].self, expected: "dictionary of strings") }
    func intArray(_ key: String) -> [Int]? { value(key, as: [Int].self, expected: "array of integers") }

    /// A string or an array of strings — the onboarding's "scalar means
    /// confirm, array means choose" shape. A scalar comes back as a one-element
    /// array so callers branch on count, not on type.
    func strings(_ key: String) -> [String]? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        if let single = raw as? String { return [single] }
        if let many = raw as? [String] { return many }
        errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: "string or array of strings")))
        return nil
    }

    /// A dictionary whose values are each a string or an array of strings
    /// (e.g. scheme → candidate bundle ids).
    func stringsDict(_ key: String) -> [String: [String]]? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        guard let dict = raw as? [String: Any] else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: "dictionary")))
            return nil
        }
        var result: [String: [String]] = [:]
        for (entry, value) in dict {
            if let single = value as? String {
                result[entry] = [single]
            } else if let many = value as? [String] {
                result[entry] = many
            } else {
                errors.add(ConfigError(path: "\(path).\(key).\(entry)", kind: .typeMismatch(expected: "string or array of strings")))
            }
        }
        return result
    }

    /// Required string; records missingKey when absent.
    func requiredString(_ key: String) -> String? {
        errors.noteRead(path: path, key: key)
        guard dictionary[key] != nil else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .missingKey))
            return nil
        }
        return string(key)
    }

    func localizedText(_ key: String) -> LocalizedText? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        guard let text = LocalizedText(plistValue: raw) else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .invalidLocalizedText))
            return nil
        }
        return text
    }

    func icon(_ key: String) -> IconSpec? {
        guard let raw = string(key) else { return nil }
        guard let icon = IconSpec(configString: raw) else {
            errors.add(ConfigError(path: "\(path).\(key)", kind: .invalidIcon(raw)))
            return nil
        }
        return icon
    }
}

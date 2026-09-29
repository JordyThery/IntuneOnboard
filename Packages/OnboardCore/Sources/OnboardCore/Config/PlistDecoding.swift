import Foundation

/// A decoder over plist dictionaries that reports errors with their key path.
struct PlistDecoder {
    let dictionary: [String: Any]
    let path: String
    private(set) var errors: ErrorCollector

    final class ErrorCollector {
        private(set) var errors: [ConfigError] = []
        func add(_ error: ConfigError) { errors.append(error) }

        /// Keys present in each node and keys read from it, for reporting
        /// unknown keys.
        private var keysPresent: [String: Set<String>] = [:]
        private var keysRead: [String: Set<String>] = [:]

        func noteNode(path: String, keys: some Sequence<String>) {
            keysPresent[path, default: []].formUnion(keys)
        }

        func noteRead(path: String, key: String) {
            keysRead[path, default: []].insert(key)
        }

        /// One error per key that was present but never read, sorted by path.
        /// Root-level `Payload*` keys are profile metadata and are exempt.
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

    /// Counts as a read for the unknown-key check.
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

    /// Optional typed value; records a type error when the type is wrong.
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

    /// A string or an array of strings, returned as an array.
    func strings(_ key: String) -> [String]? {
        errors.noteRead(path: path, key: key)
        guard let raw = dictionary[key] else { return nil }
        if let single = raw as? String { return [single] }
        if let many = raw as? [String] { return many }
        errors.add(ConfigError(path: "\(path).\(key)", kind: .typeMismatch(expected: "string or array of strings")))
        return nil
    }

    /// A dictionary whose values are strings or arrays of strings.
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

    /// Required string; records a missing-key error when absent.
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

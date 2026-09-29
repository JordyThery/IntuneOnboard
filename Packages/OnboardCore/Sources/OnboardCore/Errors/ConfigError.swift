import Foundation

/// A configuration error, with the key path where it was found.
public struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum OptionViolation: Equatable, Sendable {
        case debugForbidden
        case disallowedShape
    }

    public enum Kind: Equatable, Sendable {
        case missingKey
        case typeMismatch(expected: String)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case invalidID(String)
        case duplicateID(String)
        case unknownKind(String)
        case unknownKey
        case invalidOption(String, OptionViolation)
        case insecureURL(String)
        case invalidAccentColor(String)
        case invalidSHA256(String)
        case invalidIcon(String)
        case invalidLocalizedText
        case scriptSourceMissing
        case scriptPathInsecure(String, reason: String)
        case unreachableCombination(String)
        case invalidValue(String)
    }

    public let path: String
    public let kind: Kind

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }

    public var description: String {
        let detail: String
        switch kind {
        case .missingKey:
            detail = "required key is missing"
        case .typeMismatch(let expected):
            detail = "wrong type, expected \(expected)"
        case .unsupportedSchemaVersion(let found, let supported):
            detail = "schemaVersion \(found) is not supported (this build supports \(supported))"
        case .invalidID(let id):
            detail = "'\(id)' is not a valid id (allowed: A-Z a-z 0-9 . _ -, max 64 chars)"
        case .duplicateID(let id):
            detail = "duplicate id '\(id)' within the same phase"
        case .unknownKind(let kind):
            detail = "unknown kind '\(kind)'"
        case .unknownKey:
            detail = "unknown key — nothing in this build reads it here (misspelled, or from an older schema?)"
        case .invalidOption(let option, .debugForbidden):
            detail = "option '\(option)' is forbidden: DEBUG is controlled by the app, never by config"
        case .invalidOption(let option, .disallowedShape):
            detail = "option '\(option)' does not match the allowed KEY=value shape"
        case .insecureURL(let url):
            detail = "'\(url)' must be an https URL"
        case .invalidAccentColor(let value):
            detail = "'\(value)' is not #RRGGBB"
        case .invalidSHA256(let value):
            detail = "'\(value)' is not a 64-character hex SHA-256"
        case .invalidIcon(let value):
            detail = "'\(value)' is not a valid icon (symbol:, absolute path, bundleid:, or https URL)"
        case .invalidLocalizedText:
            detail = "must be a string or a dictionary of language code → string"
        case .scriptSourceMissing:
            detail = "script items need either 'script' (inline) or 'path'"
        case .scriptPathInsecure(let path, let reason):
            detail = "script path '\(path)' is insecure: \(reason)"
        case .unreachableCombination(let explanation):
            detail = "unreachable configuration: \(explanation)"
        case .invalidValue(let explanation):
            detail = explanation
        }
        return "\(path): \(detail)"
    }
}

/// A configuration that cannot be used.
public enum ConfigLoadError: Error, Sendable, CustomStringConvertible {
    case fileNotFound(String)
    case unreadable(String, underlying: String)
    case notADictionary(String)
    case overridePathInsecure(String, reason: String)
    case invalid(errors: [ConfigError])

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            "no configuration at \(path)"
        case .unreadable(let path, let underlying):
            "cannot read \(path): \(underlying)"
        case .notADictionary(let path):
            "\(path) is not a plist dictionary"
        case .overridePathInsecure(let path, let reason):
            "--config \(path) rejected: \(reason)"
        case .invalid(let errors):
            "configuration invalid:\n" + errors.map { "  - \($0.description)" }.joined(separator: "\n")
        }
    }
}

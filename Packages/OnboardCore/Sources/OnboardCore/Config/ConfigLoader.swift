import Foundation

/// Loads configuration from managed preferences only. User-level defaults are
/// deliberately ignored: the config contains scripts that run as root, so a
/// user-writable source would be a privilege escalation.
public enum ConfigLoader {
    public static let managedPreferencesPath =
        "/Library/Managed Preferences/\(ServiceIdentity.preferencesDomain).plist"

    /// Loads and fully validates. `overridePath` is for DEBUG builds'
    /// `--config` only and must be root-owned and not group/world-writable —
    /// checked here regardless of build configuration, defense in depth.
    public static func load(overridePath: String? = nil) throws -> Configuration {
        let path: String
        if let overridePath {
            try assertSecureOverride(overridePath)
            path = overridePath
        } else {
            path = managedPreferencesPath
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigLoadError.fileNotFound(path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(filePath: path))
        } catch {
            throw ConfigLoadError.unreadable(path, underlying: error.localizedDescription)
        }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ConfigLoadError.unreadable(path, underlying: error.localizedDescription)
        }

        guard let root = plist as? [String: Any] else {
            throw ConfigLoadError.notADictionary(path)
        }

        return try parseAndValidate(root)
    }

    /// Shared by load() and tests: parse, then whole-tree validation.
    public static func parseAndValidate(
        _ root: [String: Any],
        fileChecks: ConfigValidator.FileChecks = .live
    ) throws -> Configuration {
        let (configuration, parseErrors) = ConfigParser.parse(root)
        guard let configuration else {
            throw ConfigLoadError.invalid(errors: parseErrors)
        }
        let validationErrors = ConfigValidator.validate(configuration, fileChecks: fileChecks)
        guard validationErrors.isEmpty else {
            throw ConfigLoadError.invalid(errors: validationErrors)
        }
        return configuration
    }

    private static func assertSecureOverride(_ path: String) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            throw ConfigLoadError.fileNotFound(path)
        }
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        if owner != 0 {
            throw ConfigLoadError.overridePathInsecure(path, reason: "not owned by root")
        }
        if permissions & 0o022 != 0 {
            throw ConfigLoadError.overridePathInsecure(path, reason: "group/world-writable")
        }
    }
}

import Foundation

/// Validation across the whole configuration: duplicate ids, invalid key
/// combinations and script file permissions.
public enum ConfigValidator {
    /// Injectable for tests.
    public struct FileChecks: Sendable {
        public var attributesOfItem: @Sendable (String) -> (ownerUID: Int, permissions: Int)?

        public init(attributesOfItem: @escaping @Sendable (String) -> (ownerUID: Int, permissions: Int)?) {
            self.attributesOfItem = attributesOfItem
        }

        public static let live = FileChecks { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue ?? -1
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return (owner, permissions)
        }
    }

    public static func validate(_ configuration: Configuration, fileChecks: FileChecks = .live) -> [ConfigError] {
        var errors: [ConfigError] = []

        validateUniqueIDs(
            configuration.provisioning?.items.map(\.id) ?? [],
            path: "config.provisioning.items", into: &errors
        )
        validateUniqueIDs(
            configuration.onboarding?.items.map(\.id) ?? [],
            path: "config.onboarding.items", into: &errors
        )

        for item in configuration.provisioning?.items ?? [] {
            let path = "config.provisioning.items(id: \(item.id))"
            if case .script(let spec) = item.kind, case .path(let scriptPath) = spec.source {
                validateScriptPath(scriptPath, at: path, fileChecks: fileChecks, into: &errors)
            }
        }

        for item in configuration.onboarding?.items ?? [] {
            let path = "config.onboarding.items(id: \(item.id))"
            if case .open(_, let completion) = item.kind,
               completion == .validatePath, item.validatePath == nil {
                errors.append(ConfigError(
                    path: path,
                    kind: .unreachableCombination("completion is 'validatePath' but the item has no validatePath")
                ))
            }
            if case .defaultApps(let spec) = item.kind,
               spec.browsers.isEmpty, spec.urlSchemes.isEmpty, spec.types.isEmpty {
                errors.append(ConfigError(
                    path: path,
                    kind: .unreachableCombination("defaultApps sets no browser, urlSchemes or types")
                ))
            }
            // A single hash cannot verify several files.
            if case .wallpaper(let spec) = item.kind,
               spec.sha256 != nil, spec.sources.count > 1 {
                errors.append(ConfigError(
                    path: path,
                    kind: .unreachableCombination("sha256 requires exactly one wallpaper source")
                ))
            }
        }

        return errors
    }

    private static func validateUniqueIDs(_ ids: [String], path: String, into errors: inout [ConfigError]) {
        var seen: Set<String> = []
        for id in ids {
            if !seen.insert(id).inserted {
                errors.append(ConfigError(path: path, kind: .duplicateID(id)))
            }
        }
    }

    /// Scripts run as root, so the file must be owned by root and not
    /// writable by group or others.
    private static func validateScriptPath(
        _ scriptPath: String,
        at path: String,
        fileChecks: FileChecks,
        into errors: inout [ConfigError]
    ) {
        guard let attributes = fileChecks.attributesOfItem(scriptPath) else {
            errors.append(ConfigError(path: path, kind: .scriptPathInsecure(scriptPath, reason: "file does not exist")))
            return
        }
        if attributes.ownerUID != 0 {
            errors.append(ConfigError(path: path, kind: .scriptPathInsecure(scriptPath, reason: "not owned by root")))
        }
        if attributes.permissions & 0o022 != 0 {
            errors.append(ConfigError(path: path, kind: .scriptPathInsecure(scriptPath, reason: "group/world-writable")))
        }
    }
}

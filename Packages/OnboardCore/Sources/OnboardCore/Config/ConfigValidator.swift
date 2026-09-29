import Foundation

/// Whole-tree validation that needs more context than a single value:
/// duplicate ids, unreachable combinations, script path security.
public enum ConfigValidator {
    /// File-system checks (script path ownership) are injectable for tests.
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
            // One hash cannot vouch for several files: which download would it
            // verify? Better to refuse than to verify one and silently trust
            // the rest.
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

    /// Config scripts run as root: a path that a non-root user can rewrite is
    /// a privilege escalation, so it must be root-owned and not
    /// group/world-writable.
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

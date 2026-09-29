import Foundation

/// Provisioning state for the Mac, saved by the daemon.
public struct DeviceState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var items: [String: ItemRecord]
    /// The completion marker; never cleared.
    public var completedAt: Date?
    public var lastRunAt: Date?
    /// Consecutive preflight failures; reset when preflight passes. Limited
    /// like item attempts.
    public var preflightFailures: Int

    public init(
        schemaVersion: Int = 1,
        items: [String: ItemRecord] = [:],
        completedAt: Date? = nil,
        lastRunAt: Date? = nil,
        preflightFailures: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.completedAt = completedAt
        self.lastRunAt = lastRunAt
        self.preflightFailures = preflightFailures
    }

    /// Tolerates keys missing from older files, so the completion marker
    /// is never lost.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        items = try container.decodeIfPresent([String: ItemRecord].self, forKey: .items) ?? [:]
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        preflightFailures = try container.decodeIfPresent(Int.self, forKey: .preflightFailures) ?? 0
    }
}

/// Onboarding state for one user.
public struct UserState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var items: [String: ItemRecord]
    public var completedAt: Date?
    /// SHA-256 of the applied wallpaper.
    public var appliedWallpaperSHA256: String?
    /// Start time (`DeviceState.lastRunAt`) of the failed provisioning run
    /// this user dismissed. The failure is shown again only for a later run.
    public var dismissedProvisioningRunAt: Date?

    public init(
        schemaVersion: Int = 1,
        items: [String: ItemRecord] = [:],
        completedAt: Date? = nil,
        appliedWallpaperSHA256: String? = nil,
        dismissedProvisioningRunAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.completedAt = completedAt
        self.appliedWallpaperSHA256 = appliedWallpaperSHA256
        self.dismissedProvisioningRunAt = dismissedProvisioningRunAt
    }

    /// Tolerates keys missing from older files.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        items = try container.decodeIfPresent([String: ItemRecord].self, forKey: .items) ?? [:]
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        appliedWallpaperSHA256 = try container.decodeIfPresent(String.self, forKey: .appliedWallpaperSHA256)
        dismissedProvisioningRunAt = try container.decodeIfPresent(Date.self, forKey: .dismissedProvisioningRunAt)
    }
}

/// Reads and writes state files atomically.
///
///     /Library/Application Support/IntuneOnboard/
///         state/device.json
///         state/user-<name>.json
///         progress.json              (world-readable)
///     ~/Library/Application Support/IntuneOnboard/
///         state/user.json
public struct StateStore: Sendable {
    public let rootDirectory: URL

    public static let deviceDefaultDirectory = URL(filePath: "/Library/Application Support/IntuneOnboard")

    public init(rootDirectory: URL = StateStore.deviceDefaultDirectory) {
        self.rootDirectory = rootDirectory
    }

    public static func forCurrentUser() -> StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StateStore(rootDirectory: base.appending(path: "IntuneOnboard"))
    }

    /// The store in a named user's home directory, for callers running as
    /// root. nil when the account has no home directory.
    public static func forUser(named name: String) -> StateStore? {
        guard let home = NSHomeDirectoryForUser(name) else { return nil }
        return StateStore(
            rootDirectory: URL(filePath: home)
                .appending(path: "Library/Application Support/IntuneOnboard")
        )
    }

    public var stateDirectory: URL { rootDirectory.appending(path: "state") }
    public var progressFileURL: URL { rootDirectory.appending(path: "progress.json") }
    public var deviceStateURL: URL { stateDirectory.appending(path: "device.json") }

    public func userStateURL(userName: String? = nil) -> URL {
        if let userName {
            stateDirectory.appending(path: "user-\(userName).json")
        } else {
            stateDirectory.appending(path: "user.json")
        }
    }

    // MARK: - Load / save

    public func loadDeviceState() throws -> DeviceState? {
        try load(DeviceState.self, from: deviceStateURL)
    }

    public func saveDeviceState(_ state: DeviceState) throws {
        try save(state, to: deviceStateURL)
    }

    public func loadUserState(userName: String? = nil) throws -> UserState? {
        try load(UserState.self, from: userStateURL(userName: userName))
    }

    public func saveUserState(_ state: UserState, userName: String? = nil) throws {
        try save(state, to: userStateURL(userName: userName))
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    // MARK: - Implementation

    private func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // Move the unreadable file aside and log it, rather than letting
            // callers treat it as absent: for device.json that would discard
            // the completion marker.
            let quarantined = url.deletingLastPathComponent()
                .appending(path: url.lastPathComponent + ".corrupt")
            try? FileManager.default.removeItem(at: quarantined)
            try? FileManager.default.moveItem(at: url, to: quarantined)
            OnboardLog.daemon.error("""
            \(url.lastPathComponent, privacy: .public) exists but does not decode \
            (\(error.localizedDescription, privacy: .public)) — moved aside as \
            \(quarantined.lastPathComponent, privacy: .public); starting from blank state
            """)
            throw error
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}

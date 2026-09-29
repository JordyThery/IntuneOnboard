import Foundation

/// Device-wide provisioning state, persisted by the daemon.
public struct DeviceState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var items: [String: ItemRecord]
    /// The device completion marker: set once, never unset.
    public var completedAt: Date?
    public var lastRunAt: Date?
    /// Consecutive preflight failures, reset the moment preflight passes.
    ///
    /// Capped like an item's attempts, and for the same reason: launchd
    /// re-spawns the daemon every few seconds while a card is polling, and a
    /// preflight that cannot pass re-ran its network checks about six times a
    /// minute, indefinitely. Unlike an item there are no records to judge —
    /// nothing ran — so the count has to be kept separately.
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

    /// Hand-written for the same reason `ItemRecord`'s and `UserState`'s are:
    /// synthesized `Decodable` demands every key, and a device.json written
    /// before this field existed has none. Failing to decode it would lose
    /// the completion marker and re-provision a finished Mac.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        items = try container.decodeIfPresent([String: ItemRecord].self, forKey: .items) ?? [:]
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        preflightFailures = try container.decodeIfPresent(Int.self, forKey: .preflightFailures) ?? 0
    }
}

/// Per-user onboarding state.
public struct UserState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var items: [String: ItemRecord]
    public var completedAt: Date?
    /// SHA-256 of the applied wallpaper file, for validation.
    public var appliedWallpaperSHA256: String?
    /// The provisioning run this user has already been shown and waved past,
    /// identified by its start time (`DeviceState.lastRunAt`).
    ///
    /// A failed run is worth interrupting someone over once, not at every
    /// login for the life of the Mac — and with the attempt cap a settled
    /// failure never runs again, so the timestamp never moves and the card
    /// stays gone. It comes back only when a *newer* run has failed, which
    /// is the case where there is genuinely something new to say.
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

    /// Hand-written for the same reason `ItemRecord`'s is: synthesized
    /// `Decodable` demands every key, and a user.json written before this
    /// field existed has none. Failing to decode it would lose the user's
    /// onboarding progress and start them over.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        items = try container.decodeIfPresent([String: ItemRecord].self, forKey: .items) ?? [:]
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        appliedWallpaperSHA256 = try container.decodeIfPresent(String.self, forKey: .appliedWallpaperSHA256)
        dismissedProvisioningRunAt = try container.decodeIfPresent(Date.self, forKey: .dismissedProvisioningRunAt)
    }
}

/// Reads and writes state files. Layout (flattened per approved decision #6):
///
///     /Library/Application Support/IntuneOnboard/
///         state/device.json
///         state/user-<name>.json     (owned by the daemon, root)
///         progress.json              (root-owned, world-readable, M2)
///         cache/
///     ~/Library/Application Support/IntuneOnboard/
///         state/user.json            (written by the agent, as the user)
///
/// Writes are atomic (temp file + rename).
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

    /// A named user's store, by home directory rather than by "current user".
    ///
    /// Necessary because the reporting path runs as **root**: an Intune custom
    /// attribute is a root script, and `forCurrentUser()` would faithfully
    /// report on root's own empty state instead of the person sitting at the
    /// Mac. nil when the account has no home directory.
    public static func forUser(named name: String) -> StateStore? {
        guard let home = NSHomeDirectoryForUser(name) else { return nil }
        return StateStore(
            rootDirectory: URL(filePath: home)
                .appending(path: "Library/Application Support/IntuneOnboard")
        )
    }

    public var stateDirectory: URL { rootDirectory.appending(path: "state") }
    public var cacheDirectory: URL { rootDirectory.appending(path: "cache") }
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
        return try decoder.decode(type, from: data)
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

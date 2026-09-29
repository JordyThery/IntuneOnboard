import Foundation

/// Provisioning progress, served over XPC and written to `progress.json`
/// (root-owned, world-readable) for UIs that start while the daemon is not
/// running.
public struct ProgressSnapshot: Codable, Equatable, Sendable {
    public enum EngineState: String, Codable, Sendable {
        case waitingForConfig
        case preflight
        case running
        case completed
        case completedWithErrors
        case preflightFailed
    }

    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let outcome: ItemOutcome
        public let status: StatusKind
        /// Counts, e.g. Dock "added" and "skipped".
        public let detail: [String: Int]
        /// Text from a script's `status:` line.
        public let statusText: String?

        public init(id: String, outcome: ItemOutcome, status: StatusKind, detail: [String: Int] = [:], statusText: String? = nil) {
            self.id = id
            self.outcome = outcome
            self.status = status
            self.detail = detail
            self.statusText = statusText
        }
    }

    public let engineState: EngineState
    /// In configuration order.
    public let items: [Item]
    public let updatedAt: Date
    /// When the run started. Absent in older files.
    public let startedAt: Date?
    /// `requireADE` is set and the Mac was not enrolled through ADE. Separate
    /// from `engineState`: unlike other preflight failures, it also rules out
    /// onboarding.
    public let ineligible: Bool

    public init(
        engineState: EngineState,
        items: [Item],
        updatedAt: Date = .now,
        startedAt: Date? = nil,
        ineligible: Bool = false
    ) {
        self.engineState = engineState
        self.items = items
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.ineligible = ineligible
    }

    /// Tolerates a missing `ineligible` key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineState = try container.decode(EngineState.self, forKey: .engineState)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        ineligible = try container.decodeIfPresent(Bool.self, forKey: .ineligible) ?? false
    }

    /// A snapshot for `itemIDs`, in order, with the existing records.
    public static func make(
        engineState: EngineState,
        itemIDs: [String],
        records: [String: ItemRecord],
        statusTexts: [String: String] = [:],
        updatedAt: Date = .now,
        startedAt: Date? = nil,
        ineligible: Bool = false
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            engineState: engineState,
            items: itemIDs.map { id in
                let record = records[id]
                return Item(
                    id: id,
                    outcome: record?.outcome ?? .pending,
                    status: record?.status ?? .waiting,
                    detail: record?.detail ?? [:],
                    statusText: statusTexts[id]
                )
            },
            updatedAt: updatedAt,
            startedAt: startedAt,
            ineligible: ineligible
        )
    }

    public var completedCount: Int {
        items.filter { $0.outcome == .success || $0.outcome == .skipped }.count
    }

    public var failedCount: Int {
        items.filter { $0.outcome == .failed }.count
    }

    // MARK: - File mirror

    public func write(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            // World-readable, for the user-session UI.
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            OnboardLog.daemon.error("progress.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func read(from url: URL) -> ProgressSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProgressSnapshot.self, from: data)
    }
}

import Foundation

/// The daemon's externally visible state, served over XPC and mirrored to a
/// root-owned, world-readable progress.json so a UI that starts late (or
/// restarts after Await Final Configuration kills the session) can recover.
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
        /// Optional numeric detail (e.g. dock "added"/"skipped" counts).
        public let detail: [String: Int]
        /// Free-text status line (script `status:` output); UI shows verbatim.
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
    /// When this run began, for the elapsed time in "About this Mac".
    /// Optional because older `progress.json` files predate it.
    public let startedAt: Date?
    /// This Mac may not be configured at all — `requireADE` is set and the
    /// Mac was not enrolled through Automated Device Enrollment.
    ///
    /// Carried separately from `engineState` because the two failures that
    /// reach `preflightFailed` mean different things to the user session: an
    /// unreachable endpoint stops provisioning but leaves onboarding worth
    /// doing, while an ineligible Mac must not be touched by either stage.
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

    /// Hand-written so `ineligible` can be absent from a progress.json the
    /// running daemon has not rewritten yet.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineState = try container.decode(EngineState.self, forKey: .engineState)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        ineligible = try container.decodeIfPresent(Bool.self, forKey: .ineligible) ?? false
    }

    /// Builds a snapshot for `itemIDs` in configuration order, carrying
    /// whatever `records` already knows about each one.
    ///
    /// The daemon used to fabricate `.pending` rows here. Because launchd
    /// re-spawns it on demand, a finished device got a fresh daemon that
    /// published `.completed` over the real progress — and the UI showed
    /// "Your Mac is ready" above "0 of 4 complete".
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
            // World-readable: the user-session UI reads it without privileges.
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

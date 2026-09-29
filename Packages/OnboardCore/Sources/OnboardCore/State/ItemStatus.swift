import Foundation

/// The outcome of one item.
public enum ItemOutcome: String, Codable, Equatable, Sendable {
    case pending
    case running
    /// Ran successfully.
    case success
    /// Not applicable: disabled, already in the desired state, or an
    /// optional file is missing. Never withholds the completion marker.
    case skipped
    /// Did not succeed, or `validatePath` was missing afterwards.
    case failed

    public var isTerminal: Bool {
        switch self {
        case .success, .skipped, .failed: true
        case .pending, .running: false
        }
    }
}

/// Detailed status, shown as localized text.
public enum StatusKind: String, Codable, Equatable, Sendable {
    case waiting
    case preparing
    case downloading
    case installing
    case running
    case installed
    case done
    case failed
    case skipped
    case notNeeded
    case downloadFailed
    case hashMismatch
    case timedOut
    case awaitingUser
}

/// The stored record for one item.
public struct ItemRecord: Codable, Equatable, Sendable {
    public var outcome: ItemOutcome
    public var status: StatusKind
    /// Counts, e.g. Dock "added" and "skipped".
    public var detail: [String: Int]
    public var message: String?
    public var updatedAt: Date
    /// Times the item has run. See `ProvisioningEngine.maxAutomaticAttempts`.
    public var attempts: Int

    public init(
        outcome: ItemOutcome = .pending,
        status: StatusKind = .waiting,
        detail: [String: Int] = [:],
        message: String? = nil,
        updatedAt: Date = .now,
        attempts: Int = 0
    ) {
        self.outcome = outcome
        self.status = status
        self.detail = detail
        self.message = message
        self.updatedAt = updatedAt
        self.attempts = attempts
    }

    /// Tolerates a missing `attempts` key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try container.decode(ItemOutcome.self, forKey: .outcome)
        status = try container.decode(StatusKind.self, forKey: .status)
        detail = try container.decodeIfPresent([String: Int].self, forKey: .detail) ?? [:]
        message = try container.decodeIfPresent(String.self, forKey: .message)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}

/// The completion marker requires every required item to have succeeded or
/// been skipped.
public enum MarkerLogic {
    public static func markerEligible(
        requiredIDs: some Sequence<String>,
        records: [String: ItemRecord]
    ) -> Bool {
        for id in requiredIDs {
            guard let record = records[id] else { return false }
            switch record.outcome {
            case .success, .skipped:
                continue
            case .failed, .pending, .running:
                return false
            }
        }
        return true
    }

}

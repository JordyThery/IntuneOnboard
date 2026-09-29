import Foundation

/// A terminal or in-flight outcome for one item. The daemon persists and
/// serves these; the UI maps `StatusKind` to localized text.
public enum ItemOutcome: String, Codable, Equatable, Sendable {
    case pending
    case running
    /// Ran and validated.
    case success
    /// Deliberately not applicable (disabled, already in desired state,
    /// optional path missing). Never blocks the completion marker.
    case skipped
    /// Attempted and did not succeed, or validatePath missing afterwards.
    /// Blocks the marker when the item is required.
    case failed

    public var isTerminal: Bool {
        switch self {
        case .success, .skipped, .failed: true
        case .pending, .running: false
        }
    }
}

/// Fine-grained status codes the UI localizes (the script's ~30
/// DIALOG_STATUS_* variables become this one enum + a String Catalog).
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

/// Persisted record for one item.
public struct ItemRecord: Codable, Equatable, Sendable {
    public var outcome: ItemOutcome
    public var status: StatusKind
    /// Optional numeric detail, e.g. dock "X added, Y skipped".
    public var detail: [String: Int]
    public var message: String?
    public var updatedAt: Date
    /// How many times this item has actually been executed. The engine stops
    /// retrying a failed item automatically once this reaches its cap — see
    /// `ProvisioningEngine.maxAutomaticAttempts`.
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

    /// Hand-written so `attempts` can be absent: synthesized `Decodable`
    /// demands every key, and a device.json from an earlier build has none.
    /// Failing to decode it would hand the daemon a blank `DeviceState` —
    /// losing the completion marker and re-provisioning a finished Mac.
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

/// Marker semantics (§5.5 of the spec + approved schema):
/// the completion marker may be written only when every *required* item is
/// terminal and none of them failed. Skipped never blocks, even if required.
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

    /// Ids that a next run should retry: only unfinished or failed
    /// *required* items (successful/skipped work is never redone).
    public static func retryIDs(
        requiredIDs: some Sequence<String>,
        records: [String: ItemRecord]
    ) -> [String] {
        requiredIDs.filter { id in
            guard let record = records[id] else { return true }
            switch record.outcome {
            case .failed, .pending, .running: return true
            case .success, .skipped: return false
            }
        }
    }
}

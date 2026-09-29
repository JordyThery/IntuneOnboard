import Foundation

/// Whether the daemon may relaunch the provisioning window.
///
/// Relaunching stops after `suppress()` (⌃⌥⌘Q, reported over XPC) or after
/// `limit` relaunches, which applies even if XPC is unavailable.
public struct RelaunchPolicy: Sendable, Equatable {
    /// Allows for a force-quit or crash, but not an endless loop.
    public static let defaultLimit = 3

    public let limit: Int
    public private(set) var relaunchCount = 0
    public private(set) var isSuppressed = false

    public init(limit: Int = RelaunchPolicy.defaultLimit) {
        self.limit = limit
    }

    public var canRelaunch: Bool {
        !isSuppressed && relaunchCount < limit
    }

    /// True once the limit is reached.
    public var isExhausted: Bool {
        !isSuppressed && relaunchCount >= limit
    }

    public mutating func recordRelaunch() {
        relaunchCount += 1
    }

    public mutating func suppress() {
        isSuppressed = true
    }
}

import Foundation

/// Decides whether the daemon may put the kiosk UI back on screen.
///
/// Two independent brakes, because a kiosk that can strand a technician is
/// worse than one a user can dismiss by accident:
///
/// 1. `suppress()` — an administrator used the escape hatch (⌃⌥⌘Q) and the
///    app told us over XPC. Final for the rest of the run.
/// 2. `limit` — a hard cap on relaunches. This one matters when XPC is
///    *unavailable*, which is precisely the case where the hatch is needed
///    most and the polite signal can't get through.
///
/// Lives here rather than in the daemon target so it can be tested.
public struct RelaunchPolicy: Sendable, Equatable {
    /// Enough to survive an accidental force-quit or a crash loop, few enough
    /// that someone holding the shortcut always wins.
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

    /// True once the cap is reached — worth logging loudly, since from here on
    /// a vanished UI stays vanished while the engine keeps working.
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

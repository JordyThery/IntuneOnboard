import Foundation

/// A source of provisioning progress: the XPC client or the demo.
public protocol ProgressProviding: Sendable {
    /// The latest snapshot, or nil if none is available.
    func currentSnapshot() async -> ProgressSnapshot?

    /// Runs failed items again. Returns true if a run started.
    func requestRetry() async -> Bool

    /// Stops the daemon relaunching the window (⌃⌥⌘Q).
    func requestUISuppression() async
}

public extension ProgressProviding {
    /// No-op for sources without a daemon.
    func requestUISuppression() async {}
}

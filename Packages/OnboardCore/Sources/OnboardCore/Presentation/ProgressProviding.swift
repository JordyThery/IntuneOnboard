import Foundation

/// Where the UI gets its progress from. Two implementations: the real XPC
/// client (`OnboardServiceClient`) and the scripted `DemoProgressSource`, so
/// the provisioning UI can be built and reviewed without an ADE Mac.
public protocol ProgressProviding: Sendable {
    /// The latest snapshot, or nil when nothing is available yet.
    func currentSnapshot() async -> ProgressSnapshot?

    /// Ask the daemon to re-run failed required items.
    /// Returns true when a retry pass actually started.
    func requestRetry() async -> Bool

    /// Tell the daemon to stop putting the UI back, because an administrator
    /// is deliberately dismissing it. Without this the kiosk window reappears
    /// within a couple of seconds and the escape hatch is useless.
    func requestUISuppression() async
}

public extension ProgressProviding {
    /// Sources with no daemon behind them (the demo) have nothing to suppress.
    func requestUISuppression() async {}
}

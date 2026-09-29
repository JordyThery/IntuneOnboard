import Foundation
import OnboardCore
import os

/// Daemon-side implementation of the XPC service. Thin: reads the latest
/// snapshot from the engine coordinator and forwards retry requests.
///
/// `nonisolated` is load-bearing. This target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it these `@objc`
/// methods are implicitly main-actor isolated — and XPC calls them on its own
/// dispatch queue. The runtime's isolation check then traps
/// (`EXC_BREAKPOINT` in `dispatch_assert_queue`), which crash-looped the
/// daemon on every incoming connection. See Docs/SetupAssistant-Findings.md.
nonisolated final class OnboardService: NSObject, OnboardServiceProtocol, @unchecked Sendable {
    private let coordinator: DaemonCoordinator

    init(coordinator: DaemonCoordinator) {
        self.coordinator = coordinator
    }

    func fetchProgress(reply: @escaping @Sendable (Data?) -> Void) {
        Task {
            let snapshot = await coordinator.latestSnapshot()
            reply(snapshot.flatMap(OnboardServiceCoding.encode))
        }
    }

    func retryFailedItems(reply: @escaping @Sendable (Bool) -> Void) {
        Task {
            reply(await coordinator.requestRetry())
        }
    }

    func suppressUIRelaunch(reply: @escaping @Sendable (Bool) -> Void) {
        Task {
            await coordinator.suppressUIRelaunch()
            reply(true)
        }
    }

    /// Onboarding root operations. The item id is looked up in the daemon's own
    /// config and the console user is the daemon's own observation — the
    /// caller cannot steer either. Fresh `OnboardingRootOperations` per call:
    /// the config can arrive or change between calls.
    private var rootOperations: OnboardingRootOperations {
        OnboardingRootOperations(loadConfiguration: { try ConfigLoader.load() })
    }

    func fetchWallpaper(itemID: String, sourceIndex: Int, reply: @escaping @Sendable (Data?) -> Void) {
        let operations = rootOperations
        Task {
            let result = await operations.fetchWallpaper(itemID: itemID, sourceIndex: sourceIndex)
            reply(try? JSONEncoder().encode(result))
        }
    }

    func demoteConsoleUser(itemID: String, reply: @escaping @Sendable (Data?) -> Void) {
        let operations = rootOperations
        Task {
            let result = await operations.demoteConsoleUser(itemID: itemID)
            reply(try? JSONEncoder().encode(result))
        }
    }
}

/// Publishes the Mach service and enforces the code-signing requirement on
/// every incoming connection.
///
/// `nonisolated` for the same reason as `OnboardService`: XPC delivers
/// `shouldAcceptNewConnection` on `com.apple.NSXPCListener.service.…`, not on
/// the main actor.
nonisolated final class XPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let coordinator: DaemonCoordinator

    init(coordinator: DaemonCoordinator) {
        self.listener = NSXPCListener(machServiceName: ServiceIdentity.machServiceName)
        self.coordinator = coordinator
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
        OnboardLog.daemon.notice("XPC listener up: \(ServiceIdentity.machServiceName, privacy: .public)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let team = CodeSigning.currentTeamIdentifier() {
            // Enforcement is XPC's, not ours: this registers the requirement
            // and the system refuses any peer that fails it, before a message
            // is ever delivered. There is deliberately no error branch here —
            // the call does not throw, and an earlier `do`/`catch` around it
            // only looked like a rejection path that could never run.
            connection.setCodeSigningRequirement(CodeSigning.peerRequirement(teamIdentifier: team))
        } else {
            // Unsigned/ad-hoc development build: allow, but say so loudly.
            OnboardLog.daemon.warning("XPC: no Team ID on this build — accepting connection WITHOUT code-signing requirement (dev only)")
        }

        connection.exportedInterface = NSXPCInterface(with: OnboardServiceProtocol.self)
        connection.exportedObject = OnboardService(coordinator: coordinator)
        connection.resume()
        return true
    }
}

import Foundation
import OnboardCore
import os

/// The daemon's XPC service.
///
/// `nonisolated`: the target defaults to main-actor isolation, and XPC calls
/// these methods on its own queue.
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

    /// Created per call, because the configuration can change between calls.
    /// Item ids and the console user are resolved by the daemon, not the caller.
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

/// Publishes the Mach service and requires a matching code signature from
/// every peer. `nonisolated` for the same reason as `OnboardService`.
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
            // XPC rejects non-matching peers before any message is delivered.
            connection.setCodeSigningRequirement(CodeSigning.peerRequirement(teamIdentifier: team))
        } else {
            #if DEBUG
            OnboardLog.daemon.warning("XPC: no Team ID on this build — accepting connection WITHOUT code-signing requirement (dev only)")
            #else
            // Release builds are always signed; a missing Team ID means the
            // binary was altered.
            OnboardLog.daemon.error("XPC: no Team ID on a release build — refusing the connection")
            return false
            #endif
        }

        connection.exportedInterface = NSXPCInterface(with: OnboardServiceProtocol.self)
        connection.exportedObject = OnboardService(coordinator: coordinator)
        connection.resume()
        return true
    }
}

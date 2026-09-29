import Foundation

/// The app's XPC client. Falls back to `progress.json` when the daemon is not
/// running, which is normal before it starts and after it exits.
public actor OnboardServiceClient: ProgressProviding {
    private let machServiceName: String
    private let progressFileURL: URL
    private var connection: NSXPCConnection?
    /// Logged once, not on every poll.
    private var loggedUnavailable = false

    public init(
        machServiceName: String = ServiceIdentity.machServiceName,
        progressFileURL: URL = StateStore().progressFileURL
    ) {
        self.machServiceName = machServiceName
        self.progressFileURL = progressFileURL
    }

    // MARK: - ProgressProviding

    public func currentSnapshot() async -> ProgressSnapshot? {
        if let data = await withProxy({ service, reply in service.fetchProgress(reply: reply) }),
           let snapshot = OnboardServiceCoding.decode(data) {
            loggedUnavailable = false
            return snapshot
        }
        if !loggedUnavailable {
            OnboardLog.app.notice("daemon not answering over XPC — reading progress.json instead")
            loggedUnavailable = true
        }
        return ProgressSnapshot.read(from: progressFileURL)
    }

    public func requestRetry() async -> Bool {
        await withProxy { service, reply in service.retryFailedItems(reply: reply) } ?? false
    }

    public func requestUISuppression() async {
        let acknowledged: Bool = await withProxy { service, reply in
            service.suppressUIRelaunch(reply: reply)
        } ?? false
        OnboardLog.app.notice("""
        UI suppression requested over XPC: \
        \(acknowledged ? "acknowledged" : "no answer — the daemon's own relaunch limit applies", privacy: .public)
        """)
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - onboarding root operations

    /// A root operation failed, or the daemon was unreachable.
    public struct RootOperationError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func fetchWallpaper(itemID: String, sourceIndex: Int) async throws -> String {
        let reply = RootOperationReply.decode(await withProxy { service, replyHandler in
            service.fetchWallpaper(itemID: itemID, sourceIndex: sourceIndex, reply: replyHandler)
        })
        guard let reply else {
            throw RootOperationError(message: "the onboarding service is not reachable")
        }
        guard reply.ok, let path = reply.value else {
            throw RootOperationError(message: reply.message ?? "download failed")
        }
        return path
    }

    public func demoteConsoleUser(itemID: String) async throws -> Bool {
        let reply = RootOperationReply.decode(await withProxy { service, replyHandler in
            service.demoteConsoleUser(itemID: itemID, reply: replyHandler)
        })
        guard let reply else {
            throw RootOperationError(message: "the onboarding service is not reachable")
        }
        guard reply.ok else {
            throw RootOperationError(message: reply.message ?? "demotion failed")
        }
        return reply.value == "demoted"
    }

    // MARK: - Connection

    /// `.privileged`: the service is registered by a LaunchDaemon.
    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OnboardServiceProtocol.self)

        // Require the daemon's signature, as the daemon requires ours.
        if let team = CodeSigning.currentTeamIdentifier() {
            connection.setCodeSigningRequirement(CodeSigning.peerRequirement(teamIdentifier: team))
        } else {
            OnboardLog.app.warning("XPC: no Team ID on this build — connecting WITHOUT a code-signing requirement (dev only)")
        }

        let clear: @Sendable () -> Void = { [weak self] in
            Task { await self?.clearConnection() }
        }
        connection.invalidationHandler = clear
        connection.interruptionHandler = clear

        connection.resume()
        self.connection = connection
        return connection
    }

    private func clearConnection() {
        connection = nil
    }

    /// Performs one XPC call and resumes once, whether the reply or the
    /// error handler fires.
    private func withProxy<Value: Sendable>(
        _ call: (OnboardServiceProtocol, @escaping @Sendable (Value?) -> Void) -> Void
    ) async -> Value? {
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            let once = OneShot(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.resume(nil)
            }
            guard let service = proxy as? OnboardServiceProtocol else {
                once.resume(nil)
                return
            }
            call(service) { value in once.resume(value) }
        }
    }
}

/// A continuation that ignores repeated resumes. XPC can call both the reply
/// and the error handler when a connection drops.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

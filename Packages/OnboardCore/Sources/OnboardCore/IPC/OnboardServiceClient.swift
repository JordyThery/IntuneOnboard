import Foundation

/// App-side half of the XPC pair. Talks to the daemon's Mach service and falls
/// back to the root-owned `progress.json` mirror whenever the daemon isn't
/// reachable — which is normal twice in a run: before launchd has started it,
/// and after it exits with its verdict while the UI is still on screen.
public actor OnboardServiceClient: ProgressProviding {
    private let machServiceName: String
    private let progressFileURL: URL
    private var connection: NSXPCConnection?
    /// The daemon being absent is expected, so log it once instead of per poll.
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

    /// Errors from the daemon's side of a root operation, or its absence.
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

    /// `.privileged` because the listener lives in a LaunchDaemon, i.e. the
    /// privileged Mach bootstrap, while this process runs in a user session.
    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: OnboardServiceProtocol.self)

        // Mirror of the daemon's check: only talk to a peer signed by our own
        // Team ID. Unsigned dev builds have no Team ID and skip it, loudly.
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

    /// Runs one reply-style XPC call, resuming exactly once whether the reply
    /// block or the error handler fires.
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

/// A continuation that tolerates being resumed more than once. XPC gives no
/// guarantee that the reply block and the error handler are mutually
/// exclusive when a connection drops mid-call, and a double resume traps.
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

import Foundation

/// XPC interface the daemon exposes over its Mach service.
/// Payloads are JSON-encoded ProgressSnapshot — keeps the @objc surface tiny
/// and the real types Codable/Sendable.
@objc public protocol OnboardServiceProtocol {
    /// Current progress; reply data decodes to ProgressSnapshot.
    func fetchProgress(reply: @escaping @Sendable (Data?) -> Void)

    /// Re-run failed required provisioning items ("Retry failed" in the UI).
    /// Replies true when a retry pass was started.
    func retryFailedItems(reply: @escaping @Sendable (Bool) -> Void)

    /// Stop relaunching the UI for the rest of this run: an administrator used
    /// the escape hatch (⌃⌥⌘Q). The engine keeps going — this hides the
    /// window, it does not cancel provisioning.
    func suppressUIRelaunch(reply: @escaping @Sendable (Bool) -> Void)

    /// Onboarding root operation: download the wallpaper item's source at
    /// `sourceIndex` into the shared root-owned location. The daemon resolves
    /// the URL from its own config — the caller cannot make root fetch
    /// arbitrary URLs. Reply decodes to `RootOperationReply`.
    func fetchWallpaper(itemID: String, sourceIndex: Int, reply: @escaping @Sendable (Data?) -> Void)

    /// Onboarding root operation: remove the *console* user from the admin group,
    /// honouring the item's exclude list from the daemon's own config. The
    /// caller cannot name a user. Reply decodes to `RootOperationReply`.
    func demoteConsoleUser(itemID: String, reply: @escaping @Sendable (Data?) -> Void)
}

/// Result of an onboarding root operation, JSON over the wire like everything
/// else on this interface.
public struct RootOperationReply: Codable, Sendable {
    public var ok: Bool
    /// fetchWallpaper: the local path. demoteConsoleUser: "demoted"/"notNeeded".
    public var value: String?
    public var message: String?

    public init(ok: Bool, value: String? = nil, message: String? = nil) {
        self.ok = ok
        self.value = value
        self.message = message
    }

    public static func encoded(ok: Bool, value: String? = nil, message: String? = nil) -> Data? {
        try? JSONEncoder().encode(RootOperationReply(ok: ok, value: value, message: message))
    }

    public static func decode(_ data: Data?) -> RootOperationReply? {
        data.flatMap { try? JSONDecoder().decode(RootOperationReply.self, from: $0) }
    }
}

public enum OnboardServiceCoding {
    public static func encode(_ snapshot: ProgressSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) -> ProgressSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProgressSnapshot.self, from: data)
    }
}

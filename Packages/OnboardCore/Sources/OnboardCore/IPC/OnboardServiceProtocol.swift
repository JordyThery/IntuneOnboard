import Foundation

/// The daemon's XPC interface. Payloads are JSON.
@objc public protocol OnboardServiceProtocol {
    /// Current progress, as a JSON `ProgressSnapshot`.
    func fetchProgress(reply: @escaping @Sendable (Data?) -> Void)

    /// Runs failed provisioning items again. Replies true if a run started.
    func retryFailedItems(reply: @escaping @Sendable (Bool) -> Void)

    /// Stops relaunching the UI for this run (⌃⌥⌘Q). Provisioning continues.
    func suppressUIRelaunch(reply: @escaping @Sendable (Bool) -> Void)

    /// Downloads the wallpaper item's source at `sourceIndex` to the shared
    /// location. The URL comes from the daemon's configuration. Replies with a
    /// JSON `RootOperationReply`.
    func fetchWallpaper(itemID: String, sourceIndex: Int, reply: @escaping @Sendable (Data?) -> Void)

    /// Removes the console user from the admin group, unless excluded by the
    /// item. Replies with a JSON `RootOperationReply`.
    func demoteConsoleUser(itemID: String, reply: @escaping @Sendable (Data?) -> Void)
}

/// The result of a root operation.
public struct RootOperationReply: Codable, Sendable {
    public var ok: Bool
    /// fetchWallpaper: the local path. demoteConsoleUser: "demoted" or "notNeeded".
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

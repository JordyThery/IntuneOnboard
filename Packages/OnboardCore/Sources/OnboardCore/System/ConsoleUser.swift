import Foundation
import SystemConfiguration

/// A snapshot of the current console user, read from the SCDynamicStore.
/// This is the only source of truth for "who owns the console" — the daemon
/// never trusts a username supplied by a client.
public struct ConsoleUser: Equatable, Sendable {
    public let name: String
    public let uid: uid_t
    public let gid: gid_t

    public init(name: String, uid: uid_t, gid: gid_t) {
        self.name = name
        self.uid = uid
        self.gid = gid
    }

    /// The current console user, or nil when nobody owns the console.
    public static func current() -> ConsoleUser? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else {
            return nil
        }
        return ConsoleUser(name: name, uid: uid, gid: gid)
    }

    /// True for the Setup Assistant user during ADE enrollment.
    public var isSetupAssistant: Bool { name == "_mbsetupuser" }

    /// True while the login window owns the console.
    public var isLoginWindow: Bool { name == "loginwindow" }

    /// A real interactive end user: not root, not Setup Assistant's
    /// _mbsetupuser, not the login window's own session.
    public var isRealUser: Bool { !isSetupAssistant && !isLoginWindow && name != "root" }
}

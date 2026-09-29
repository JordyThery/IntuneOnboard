import Foundation
import SystemConfiguration

/// The console user, from SCDynamicStore. The daemon never accepts a user
/// name from a client.
public struct ConsoleUser: Equatable, Sendable {
    public let name: String
    public let uid: uid_t
    public let gid: gid_t

    public init(name: String, uid: uid_t, gid: gid_t) {
        self.name = name
        self.uid = uid
        self.gid = gid
    }

    /// nil when nobody is logged in at the console.
    public static func current() -> ConsoleUser? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else {
            return nil
        }
        return ConsoleUser(name: name, uid: uid, gid: gid)
    }

    /// The Setup Assistant user during enrollment.
    public var isSetupAssistant: Bool { name == "_mbsetupuser" }

    /// The login window.
    public var isLoginWindow: Bool { name == "loginwindow" }

    /// A real user: not root, `_mbsetupuser` or the login window.
    public var isRealUser: Bool { !isSetupAssistant && !isLoginWindow && name != "root" }
}

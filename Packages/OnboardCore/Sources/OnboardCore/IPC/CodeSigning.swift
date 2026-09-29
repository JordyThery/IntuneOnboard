import Foundation
import Security

/// Code-signing checks for XPC. Each side requires its peer to have the same
/// Team ID as itself, read at runtime.
public enum CodeSigning {
    /// This process's Team ID; nil for unsigned builds.
    public static func currentTeamIdentifier() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let codeRef else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(codeRef, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Requirement for the XPC peer: Apple-issued certificate, this process's
    /// Team ID, and the app's or the daemon's signing identifier.
    /// `identifier` matches exactly; it takes no wildcards.
    public static func peerRequirement(teamIdentifier: String) -> String {
        """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and (identifier "\(ServiceIdentity.bundleIdentifier)" \
        or identifier "\(ServiceIdentity.daemonSigningIdentifier)")
        """
    }
}

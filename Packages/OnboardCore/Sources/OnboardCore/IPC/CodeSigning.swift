import Foundation
import Security

/// Code-signing identity helpers for mutual XPC verification.
/// Both sides require the peer to be signed by the *same Team ID as
/// themselves*, derived at runtime — no hardcoded identities in the repo.
public enum CodeSigning {
    /// The current process's Team ID, or nil for unsigned/ad-hoc builds.
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

    /// Requirement string for the XPC peer: Apple-issued chain, the same Team
    /// ID as this process, and one of our two signing identifiers.
    ///
    /// The identifiers are listed explicitly on purpose. `identifier` takes an
    /// exact match — a trailing `*` is compared literally, not as a wildcard —
    /// so the prefix form this used to carry rejected *both* sides of the
    /// connection as soon as the build was signed. Ad-hoc builds have no Team
    /// ID and skip the check, which is why it went unnoticed until M3.
    public static func peerRequirement(teamIdentifier: String) -> String {
        """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)" \
        and (identifier "\(ServiceIdentity.bundleIdentifier)" \
        or identifier "\(ServiceIdentity.daemonSigningIdentifier)")
        """
    }
}

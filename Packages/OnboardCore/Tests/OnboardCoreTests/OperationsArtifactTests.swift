import Foundation
import Testing
@testable import OnboardCore

/// The two files an administrator uploads alongside the package. Neither is
/// exercised by running the app, so nothing else would notice them rotting:
/// a renamed launchd label or a moved install path breaks them silently, on
/// the Mac rather than here.
@Suite struct OperationsArtifactTests {
    private var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every label we install, read from the launchd plists themselves.
    private func installedLabels() throws -> [String] {
        let directory = repoRoot.appending(path: "LaunchServices")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
        return try files.map { url in
            let plist = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url), format: nil
            ) as? [String: Any]
            return plist?["Label"] as? String ?? ""
        }
    }

    @Test func loginItemsProfileApprovesEveryJobWeInstall() throws {
        let url = repoRoot.appending(path: "Deploy/managed-login-items.mobileconfig")
        let profile = try #require(
            try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil) as? [String: Any]
        )
        // Device channel only, and it must not land per-user.
        #expect(profile["PayloadType"] as? String == "Configuration")
        #expect(profile["PayloadScope"] as? String == "System")

        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        let payload = try #require(payloads.first)
        #expect(payload["PayloadType"] as? String == "com.apple.servicemanagement")

        let rules = try #require(payload["Rules"] as? [[String: String]])
        #expect(rules.allSatisfy { $0["Comment"]?.isEmpty == false }, "each rule should say what it is for")

        let prefixes = rules.filter { $0["RuleType"] == "LabelPrefix" }.compactMap { $0["RuleValue"] }
        let labels = try installedLabels()
        #expect(!labels.isEmpty)
        for label in labels {
            #expect(
                prefixes.contains { label.hasPrefix($0) },
                "no rule approves `\(label)` — the user would be asked about it and could switch it off"
            )
        }
    }

    @Test func theCustomAttributePointsAtWhereWeActuallyInstall() throws {
        let script = try String(
            contentsOf: repoRoot.appending(path: "Deploy/custom-attribute-onboard-status.sh"),
            encoding: .utf8
        )
        // The path the pkg really uses, as built by Scripts/build-pkg.sh.
        #expect(script.contains("/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"))

        // Intune reads stdout as the value and treats a non-zero exit as a
        // failed script, which would hide "this Mac has no package yet".
        #expect(script.contains("not installed"))
        #expect(!script.contains("exit 1"), "every path must exit 0 so the value is reported, not an error")

        // `status` is a read-only alias for $? in zsh: assigning to it fails
        // and silently yields an empty attribute for every Mac.
        #expect(!script.contains("\nstatus="), "do not assign to `status` in zsh")
    }
}

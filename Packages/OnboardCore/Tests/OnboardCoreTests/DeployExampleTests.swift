import Foundation
import Testing
@testable import OnboardCore

/// The example configs shipped in Deploy/ must always parse and validate —
/// they are the first thing an admin copies.
@Suite struct DeployExampleTests {
    private var repoRoot: URL {
        // …/Packages/OnboardCore/Tests/OnboardCoreTests/DeployExampleTests.swift → repo root
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let permissiveChecks = ConfigValidator.FileChecks { _ in (ownerUID: 0, permissions: 0o755) }

    @Test func preferenceFileExampleIsValid() throws {
        let url = repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.plist")
        let data = try Data(contentsOf: url)
        let root = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let configuration = try ConfigLoader.parseAndValidate(root, fileChecks: permissiveChecks)
        #expect(configuration.provisioning?.items.count == 4)
        #expect(configuration.onboarding?.items.count == 4)
        #expect(configuration.organization?.name == "Contoso")
    }

    @Test func mobileconfigPayloadIsValid() throws {
        let configuration = try ConfigLoader.parseAndValidate(
            try mobileconfigSettings(),
            fileChecks: permissiveChecks
        )
        #expect(configuration.provisioning?.items.count == 4)
        #expect(configuration.onboarding?.items.count == 4)
    }

    /// The `.mobileconfig` (Custom profile) and the `.plist` (Preference file)
    /// are two routes to the same managed preferences, and an admin picks one.
    /// They drifted apart once — the mobileconfig was missing `onboarding`,
    /// `network` and `requireADE` — which is exactly the kind of difference
    /// nobody notices until a device behaves differently. Regenerate the
    /// mobileconfig payload from the plist if this fails.
    @Test func mobileconfigAndPlistCarryTheSameSettings() throws {
        let fromMobileconfig = try mobileconfigSettings()
        let fromPlist = try preferenceFileSettings()

        #expect(
            Set(fromMobileconfig.keys) == Set(fromPlist.keys),
            "top-level keys differ: mobileconfig \(Set(fromMobileconfig.keys).sorted()) vs plist \(Set(fromPlist.keys).sorted())"
        )
        // Compare as plist data rather than Any: NSDictionary equality on
        // plist-derived values is exactly the comparison we want here.
        #expect(
            (fromMobileconfig as NSDictionary) == (fromPlist as NSDictionary),
            "the mobileconfig payload and the preference file no longer match"
        )
    }

    /// Intune's Preference file profile rejects a wrapped document with
    /// "We couldn't validate your file" (-2016341103): it wants bare key/value
    /// pairs. The Custom profile route needs a whole profile. So the plist must
    /// stay a full document and the mobileconfig must stay a profile.
    @Test func deployFilesKeepTheShapeTheirUploadRouteExpects() throws {
        let plist = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.plist"))
        let profile = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.mobileconfig"))

        for data in [plist, profile] {
            // No BOM and no leading whitespace: both break Intune's upload.
            #expect(data.first == UInt8(ascii: "<"))
        }
        let parsedProfile = try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any]
        #expect(parsedProfile?["PayloadType"] as? String == "Configuration")
        #expect(parsedProfile?["PayloadScope"] as? String == "System", "must be device-scoped, or it lands under /Library/Managed Preferences/<user>/")
    }

    // MARK: - The annotated example profile

    @Test func examplePlistIsValid() throws {
        let configuration = try ConfigLoader.parseAndValidate(
            try settings(at: "Deploy/be.jordythery.intuneonboard.example.plist"),
            fileChecks: permissiveChecks
        )
        #expect(configuration.provisioning?.items.count == 6)
        #expect(configuration.onboarding?.items.count == 7)
        // Nothing illustrative may block the completion marker, so the file
        // stays safe to deploy as a smoke test.
        let items = (configuration.provisioning?.items.map(\.required) ?? [])
            + (configuration.onboarding?.items.map(\.required) ?? [])
        #expect(items.allSatisfy { $0 == false })
    }

    /// The point of the example profile is that it documents *everything*.
    /// The key list is extracted from the parser's own source rather than
    /// hard-coded here, so adding a configuration key without documenting it
    /// fails this test instead of quietly shipping.
    @Test func exampleProfileDocumentsEveryKeyTheParserReads() throws {
        let keys = try parserKeys()
        #expect(keys.count >= 60, "the key extraction stopped working; it found only \(keys.count)")

        let url = repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.example.plist")
        let text = try String(contentsOf: url, encoding: .utf8)
        let present = try keysPresent(in: settings(at: "Deploy/be.jordythery.intuneonboard.example.plist"))

        // `sha256` ships commented out on purpose: a placeholder hash would
        // fail the wallpaper item on every Mac, so it is documented in prose
        // with the real value left to the admin.
        // `deviceNameTemplate` ships commented out because a live template
        // would rename every Mac this smoke-test profile is deployed to.
        let intentionallyCommentedOut: Set<String> = [
            "sha256", "deviceNameTemplate",
        ]

        for key in keys {
            #expect(text.contains("<key>\(key)</key>"), "the example profile never mentions `\(key)`")
            if !intentionallyCommentedOut.contains(key) {
                #expect(present.contains(key), "`\(key)` is only in a comment — it should be live in the example profile")
            }
        }
    }

    @Test func exampleMobileconfigCarriesTheSameSettings() throws {
        let fromProfile = try payload(of: "Deploy/be.jordythery.intuneonboard.example.mobileconfig")
        let fromPlist = try settings(at: "Deploy/be.jordythery.intuneonboard.example.plist")

        #expect(
            Set(fromProfile.keys) == Set(fromPlist.keys),
            "top-level keys differ: profile \(Set(fromProfile.keys).sorted()) vs plist \(Set(fromPlist.keys).sorted())"
        )
        #expect(
            (fromProfile as NSDictionary) == (fromPlist as NSDictionary),
            "the example mobileconfig and example plist no longer match — regenerate with Scripts/make-example-profile.sh"
        )
    }

    @Test func exampleFilesKeepTheShapeTheirUploadRouteExpects() throws {
        let plist = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.example.plist"))
        let profile = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.example.mobileconfig"))
        for data in [plist, profile] {
            #expect(data.first == UInt8(ascii: "<"), "a BOM or leading whitespace breaks Intune's upload")
        }
        let parsed = try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any]
        #expect(parsed?["PayloadType"] as? String == "Configuration")
        #expect(parsed?["PayloadScope"] as? String == "System")
    }

    // MARK: - Helpers

    /// Every accessor `PlistDecoder` offers, read from its own source rather
    /// than listed here. A hard-coded list silently shrank this test's
    /// coverage once: `strings` and `stringsDict` were missing from it, so
    /// keys read through them — `dockStrategy`, `urlSchemes`, `types` — were
    /// never checked against the example profile at all.
    private func decoderAccessors() throws -> [String] {
        let source = try String(
            contentsOf: repoRoot.appending(path: "Packages/OnboardCore/Sources/OnboardCore/Config/PlistDecoding.swift"),
            encoding: .utf8
        )
        let declaration = /func ([a-zA-Z]+)\(_ key: String\)/
        let names = Set(source.matches(of: declaration).map { String($0.output.1) })
        // Longest first: the alternation is ordered, and `string` would
        // otherwise shadow `stringArray` and the rest.
        return names.sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// Every key name the parser asks for, read out of its source. Two call
    /// shapes: the `PlistDecoder` accessors, and `parseURLList(_:key:)`.
    private func parserKeys() throws -> Set<String> {
        let directory = repoRoot.appending(path: "Packages/OnboardCore/Sources/OnboardCore/Config")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        let accessors = try decoderAccessors()
        #expect(accessors.count >= 12, "accessor extraction found only \(accessors.count)")
        let accessor = try Regex("(?:\(accessors.joined(separator: "|")))\\(\"([A-Za-z0-9_]+)\"\\)")
        let keyLabel = /key:\s*"([A-Za-z0-9_]+)"/

        var keys: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: accessor) {
                if let captured = match[1].substring { keys.insert(String(captured)) }
            }
            for match in source.matches(of: keyLabel) {
                keys.insert(String(match.output.1))
            }
        }
        return keys
    }

    /// Every dictionary key anywhere in a parsed plist.
    private func keysPresent(in value: Any) throws -> Set<String> {
        var found: Set<String> = []
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                found.insert(key)
                found.formUnion(try keysPresent(in: child))
            }
        } else if let array = value as? [Any] {
            for child in array {
                found.formUnion(try keysPresent(in: child))
            }
        }
        return found
    }

    private func settings(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appending(path: path))
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func payload(of path: String) throws -> [String: Any] {
        let profile = try settings(at: path)
        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        let payload = try #require(payloads.first)
        #expect(payload["PayloadType"] as? String == ServiceIdentity.preferencesDomain)
        return payload.filter { !$0.key.hasPrefix("Payload") }
    }

    private func preferenceFileSettings() throws -> [String: Any] {
        let url = repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.plist")
        let data = try Data(contentsOf: url)
        return try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func mobileconfigSettings() throws -> [String: Any] {
        let url = repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.mobileconfig")
        let data = try Data(contentsOf: url)
        let profile = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let payloads = try #require(profile["PayloadContent"] as? [[String: Any]])
        let payload = try #require(payloads.first)
        #expect(
            payload["PayloadType"] as? String == ServiceIdentity.preferencesDomain,
            "the payload type is the preference domain — that is what puts the file in /Library/Managed Preferences/"
        )
        // Strip the Payload* wrapper keys; the rest is our domain content.
        return payload.filter { !$0.key.hasPrefix("Payload") }
    }
}

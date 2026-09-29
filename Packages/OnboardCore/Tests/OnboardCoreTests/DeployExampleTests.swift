import Foundation
import Testing
@testable import OnboardCore

/// The example profiles in Deploy/ parse and validate.
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

    /// Each `.mobileconfig` carries the same settings as its `.plist`.
    @Test func mobileconfigAndPlistCarryTheSameSettings() throws {
        let fromMobileconfig = try mobileconfigSettings()
        let fromPlist = try preferenceFileSettings()

        #expect(
            Set(fromMobileconfig.keys) == Set(fromPlist.keys),
            "top-level keys differ: mobileconfig \(Set(fromMobileconfig.keys).sorted()) vs plist \(Set(fromPlist.keys).sorted())"
        )
        // NSDictionary equality compares plist values correctly.
        #expect(
            (fromMobileconfig as NSDictionary) == (fromPlist as NSDictionary),
            "the mobileconfig payload and the preference file no longer match"
        )
    }

    /// The `.plist` is a complete document and the `.mobileconfig` a profile.
    @Test func deployFilesKeepTheShapeTheirUploadRouteExpects() throws {
        let plist = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.plist"))
        let profile = try Data(contentsOf: repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.mobileconfig"))

        for data in [plist, profile] {
            // A BOM or leading whitespace breaks the Intune upload.
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
        // Example items are optional, so the profile is safe to deploy.
        let items = (configuration.provisioning?.items.map(\.required) ?? [])
            + (configuration.onboarding?.items.map(\.required) ?? [])
        #expect(items.allSatisfy { $0 == false })
    }

    /// The example profile mentions every key the parser reads. Keys are
    /// taken from the parser's source.
    @Test func exampleProfileDocumentsEveryKeyTheParserReads() throws {
        let keys = try parserKeys()
        #expect(keys.count >= 60, "the key extraction stopped working; it found only \(keys.count)")

        let url = repoRoot.appending(path: "Deploy/be.jordythery.intuneonboard.example.plist")
        let text = try String(contentsOf: url, encoding: .utf8)
        let present = try keysPresent(in: settings(at: "Deploy/be.jordythery.intuneonboard.example.plist"))

        // Commented out in the example: a placeholder `sha256` would fail,
        // and a live `deviceNameTemplate` would rename test Macs.
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

    /// `PlistDecoder`'s accessors, read from its source.
    private func decoderAccessors() throws -> [String] {
        let source = try String(
            contentsOf: repoRoot.appending(path: "Packages/OnboardCore/Sources/OnboardCore/Config/PlistDecoding.swift"),
            encoding: .utf8
        )
        let declaration = /func ([a-zA-Z]+)\(_ key: String\)/
        let names = Set(source.matches(of: declaration).map { String($0.output.1) })
        // Longest first, so `string` does not match `stringArray`.
        return names.sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// Keys read by the parser: `PlistDecoder` accessors and
    /// `parseURLList(_:key:)`.
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

    /// All dictionary keys in a plist.
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
        // Without the Payload* wrapper keys.
        return payload.filter { !$0.key.hasPrefix("Payload") }
    }
}

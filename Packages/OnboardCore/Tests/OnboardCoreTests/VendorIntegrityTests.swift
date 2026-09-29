import CryptoKit
import Foundation
import Testing
@testable import OnboardCore

/// Mirrors Scripts/verify-installomator.sh: the pinned SHA-256 matches and
/// the behaviour the runtime depends on is present.
@Suite struct VendorIntegrityTests {
    private var vendorDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Vendor")
    }

    @Test func installomatorMatchesPin() throws {
        let directory = vendorDirectory.appending(path: "Installomator")
        let script = try Data(contentsOf: directory.appending(path: "Installomator.sh"))
        let pinned = try String(contentsOf: directory.appending(path: "PINNED_SHA256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let actual = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        #expect(actual == pinned, "Vendored Installomator drifted from its pin — rerun Scripts/vendor-helpers.sh deliberately")

        let text = String(decoding: script, as: UTF8.self)
        #expect(text.contains("\nDEBUG="), "DEBUG= default missing")
        #expect(text.contains("eval"), "argument eval handling changed")
    }

    @Test func helperBinariesPresentWithRecords() throws {
        for name in ["dockutil", "desktoppr", "utiluti"] {
            let directory = vendorDirectory.appending(path: name)
            let binary = directory.appending(path: name)
            #expect(FileManager.default.isExecutableFile(atPath: binary.path), "\(name) missing or not executable")

            let recorded = try String(contentsOf: directory.appending(path: "SHA256"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = SHA256.hash(data: try Data(contentsOf: binary))
                .map { String(format: "%02x", $0) }.joined()
            #expect(actual == recorded, "\(name) binary drifted from its recorded SHA-256")

            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "LICENSE").path), "\(name) LICENSE missing")
        }
    }
}

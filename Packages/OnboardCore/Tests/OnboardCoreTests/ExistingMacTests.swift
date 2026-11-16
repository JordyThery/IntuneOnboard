import Foundation
import Testing
@testable import OnboardCLI
@testable import OnboardCore

/// `existingMacs`: Macs set up before the rollout are marked finished once.
@Suite struct ExistingMacTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func configuration(skip: Bool = true, hours: Int = 24, dryRun: Bool = false) -> Configuration {
        Configuration(dryRun: dryRun, existingMacs: .init(skip: skip, setupOlderThanHours: hours))
    }

    private func hoursAgo(_ hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    @Test func aMacSetUpBeforeTheThresholdIsExisting() {
        #expect(ExistingMac.applies(configuration: configuration(), deviceState: nil,
                                    setupCompletedAt: hoursAgo(24), now: now))
        #expect(ExistingMac.applies(configuration: configuration(), deviceState: nil,
                                    setupCompletedAt: hoursAgo(24 * 400), now: now))
    }

    @Test func aRecentlySetUpMacIsNew() {
        #expect(!ExistingMac.applies(configuration: configuration(), deviceState: nil,
                                     setupCompletedAt: hoursAgo(23.9), now: now))
        #expect(!ExistingMac.applies(configuration: configuration(hours: 72), deviceState: nil,
                                     setupCompletedAt: hoursAgo(48), now: now))
    }

    @Test func aMacStillInSetupAssistantIsNew() {
        #expect(!ExistingMac.applies(configuration: configuration(), deviceState: nil,
                                     setupCompletedAt: nil, now: now))
    }

    /// Once the daemon has saved state, the Mac is never reclassified, so a
    /// new Mac does not become "existing" a day into its onboarding.
    @Test func theDecisionIsTakenOnlyBeforeTheFirstRun() {
        #expect(!ExistingMac.applies(configuration: configuration(), deviceState: DeviceState(),
                                     setupCompletedAt: hoursAgo(1000), now: now))
    }

    @Test func offByDefaultAndNeverInADryRun() {
        #expect(!ExistingMac.applies(configuration: Configuration(), deviceState: nil,
                                     setupCompletedAt: hoursAgo(1000), now: now))
        #expect(!ExistingMac.applies(configuration: configuration(skip: false), deviceState: nil,
                                     setupCompletedAt: hoursAgo(1000), now: now))
        #expect(!ExistingMac.applies(configuration: configuration(dryRun: true), deviceState: nil,
                                     setupCompletedAt: hoursAgo(1000), now: now))
        #expect(!ExistingMac.applies(configuration: nil, deviceState: nil,
                                     setupCompletedAt: hoursAgo(1000), now: now))
    }

    @Test func setupTimeIsTheMarkerFilesModificationDate() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-done-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ExistingMac.setupCompletedAt(url: url) == nil)
        try Data().write(to: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        #expect(ExistingMac.setupCompletedAt(url: url) == date)
    }

    // MARK: - Profile

    @Test func parsesTheProfileKeys() {
        let (configuration, errors) = ConfigParser.parse([
            "existingMacs": ["skip": true, "setupOlderThanHours": 72] as [String: Any],
        ])
        #expect(errors.isEmpty)
        #expect(configuration?.existingMacs == .init(skip: true, setupOlderThanHours: 72))
    }

    @Test func absentKeysKeepTheOldBehaviour() {
        #expect(ConfigParser.parse([:]).configuration?.existingMacs == nil)
        let defaults = ConfigParser.parse(["existingMacs": [String: Any]()]).configuration?.existingMacs
        #expect(defaults == .init(skip: false, setupOlderThanHours: 24))
    }

    @Test func rejectsAThresholdOutOfRange() {
        for hours in [0, -1, 8761] {
            let (configuration, errors) = ConfigParser.parse([
                "existingMacs": ["skip": true, "setupOlderThanHours": hours] as [String: Any],
            ])
            #expect(configuration == nil)
            #expect(errors.map(\.path) == ["config.existingMacs.setupOlderThanHours"])
        }
    }

    @Test func rejectsUnknownKeys() {
        let (_, errors) = ConfigParser.parse(["existingMacs": ["skipp": true] as [String: Any]])
        #expect(!errors.isEmpty)
    }

    // MARK: - State and reporting

    @Test func theFlagSurvivesARoundTripAndOldFilesReadAsFalse() throws {
        let store = StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "onboard-tests-\(UUID().uuidString)"))
        defer { try? store.reset() }
        try store.saveDeviceState(DeviceState(completedAt: now, skippedAsExisting: true))
        let loaded = try #require(try store.loadDeviceState())
        #expect(loaded.skippedAsExisting)
        #expect(loaded.completedAt == now)

        try Data(#"{"schemaVersion": 1, "completedAt": "2026-01-01T00:00:00Z"}"#.utf8).write(to: store.deviceStateURL)
        #expect(try #require(try store.loadDeviceState()).skippedAsExisting == false)
    }

    @Test func theUserMarkerIsWrittenOnceAndNeverReplaced() throws {
        let store = StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "onboard-tests-\(UUID().uuidString)"))
        defer { try? store.reset() }
        ExistingMac.recordUserSkipped(store: store)
        let first = try #require(try store.loadUserState())
        #expect(first.completedAt != nil)

        var inProgress = UserState()
        inProgress.items["dock"] = ItemRecord(outcome: .success, status: .done)
        try store.saveUserState(inProgress)
        ExistingMac.recordUserSkipped(store: store)
        let kept = try #require(try store.loadUserState())
        #expect(kept.completedAt == nil)
        #expect(kept.items.keys.sorted() == ["dock"])
    }

    @Test func statusSaysTheMacWasSkipped() {
        let device = DeviceState(completedAt: now, skippedAsExisting: true)
        #expect(
            Status.singleLine(device: device, onboarding: ("jordy", UserState(completedAt: now)))
                == "provisioning: skipped (existing Mac) · onboarding: complete (jordy)"
        )
    }

    /// With the marker present, the existing completed-Mac path keeps the app hidden.
    @Test func aSkippedMacPresentsNothing() {
        #expect(!UserSessionGate.shouldPresent(deviceCompleted: true, provisioning: .nothing))
    }
}

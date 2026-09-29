import CoreGraphics
import Foundation
import Testing
@testable import OnboardCore

@Suite struct StateStoreTests {
    private func makeStore() throws -> StateStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "onboard-tests-\(UUID().uuidString)")
        return StateStore(rootDirectory: directory)
    }

    @Test func deviceStateRoundTrip() throws {
        let store = try makeStore()
        defer { try? store.reset() }

        #expect(try store.loadDeviceState() == nil)

        var state = DeviceState()
        state.items["m365"] = ItemRecord(outcome: .success, status: .installed)
        state.lastRunAt = Date(timeIntervalSince1970: 1_760_000_000)
        try store.saveDeviceState(state)

        let loaded = try #require(try store.loadDeviceState())
        #expect(loaded.items["m365"]?.outcome == .success)
        #expect(loaded.completedAt == nil)
    }

    @Test func userStateRoundTripAndReset() throws {
        let store = try makeStore()
        defer { try? store.reset() }

        var state = UserState()
        state.appliedWallpaperSHA256 = String(repeating: "ab", count: 32)
        try store.saveUserState(state, userName: "jordy")

        let loaded = try #require(try store.loadUserState(userName: "jordy"))
        #expect(loaded.appliedWallpaperSHA256?.count == 64)

        try store.reset()
        #expect(try store.loadUserState(userName: "jordy") == nil)
    }

    /// A file that exists but will not decode is quarantined, not treated as
    /// blank: for device.json the difference is the completion marker, and
    /// "corrupt" silently read as "no state" would re-provision a finished
    /// Mac. The load still throws (callers use `try?` and start blank), but
    /// the evidence survives under a name the next load will not read.
    @Test func corruptStateIsQuarantinedNotBlanked() throws {
        let store = try makeStore()
        defer { try? store.reset() }

        try FileManager.default.createDirectory(
            at: store.deviceStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not json".utf8).write(to: store.deviceStateURL)

        #expect(throws: (any Error).self) { try store.loadDeviceState() }

        let quarantined = store.deviceStateURL
            .deletingLastPathComponent()
            .appending(path: "device.json.corrupt")
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        #expect(!FileManager.default.fileExists(atPath: store.deviceStateURL.path))
        // And the next load is a clean "no state", not another throw.
        #expect(try store.loadDeviceState() == nil)
    }
}

@Suite struct RotatingFileSinkTests {
    @Test func rotatesAtLimitAndPrunes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "onboard-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appending(path: "onboard.log")

        // 0 MB limit → every write rotates; keep 2 archives.
        let sink = RotatingFileSink(fileURL: logURL, maxFileSizeMB: 0, keepArchives: 2)
        for index in 0..<5 {
            sink.write("line \(index)")
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(contents.contains("onboard.log.1"))
        #expect(contents.contains("onboard.log.2"))
        #expect(!contents.contains("onboard.log.3"), "keepArchives=2 must prune older archives, got \(contents)")

        let newest = try String(contentsOf: directory.appending(path: "onboard.log.1"), encoding: .utf8)
        #expect(newest.contains("line 4"))
    }
}

@Suite struct PeerRequirementTests {
    /// The requirement is a string handed to the code-signing machinery, so a
    /// typo is invisible until a signed build refuses to talk to itself. These
    /// guard the two mistakes that actually happened.
    @Test func namesBothSigningIdentitiesExactly() {
        let requirement = CodeSigning.peerRequirement(teamIdentifier: "TEAMID1234")
        #expect(requirement.contains("identifier \"be.jordythery.intuneonboard\""))
        #expect(requirement.contains("identifier \"be.jordythery.intuneonboard.daemon\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"TEAMID1234\""))
        #expect(requirement.contains("anchor apple generic"))
    }

    /// `identifier` compares exactly: a trailing `*` is matched literally and
    /// rejects every peer. Never reintroduce a prefix form here.
    @Test func usesNoWildcard() {
        #expect(!CodeSigning.peerRequirement(teamIdentifier: "TEAMID1234").contains("*"))
    }

    @Test func daemonIdentifierIsUnderTheAppIdentifier() {
        // build-pkg.sh passes "$IDENTIFIER.daemon" to codesign --identifier.
        #expect(ServiceIdentity.daemonSigningIdentifier == ServiceIdentity.bundleIdentifier + ".daemon")
    }
}

@Suite struct RelaunchPolicyTests {
    @Test func relaunchesUpToTheLimitThenStops() {
        var policy = RelaunchPolicy(limit: 3)
        for _ in 0..<3 {
            #expect(policy.canRelaunch)
            policy.recordRelaunch()
        }
        #expect(!policy.canRelaunch)
        #expect(policy.isExhausted)
        #expect(policy.relaunchCount == 3)
    }

    /// The escape hatch has to win immediately, whatever the count says.
    @Test func suppressionWinsAtOnce() {
        var policy = RelaunchPolicy()
        #expect(policy.canRelaunch)
        policy.suppress()
        #expect(!policy.canRelaunch)
        #expect(policy.isSuppressed)
        // Suppressed is a deliberate dismissal, not a fault: not "exhausted".
        #expect(!policy.isExhausted)
    }

    @Test func suppressionIsIdempotentAndFinal() {
        var policy = RelaunchPolicy()
        policy.suppress()
        policy.suppress()
        policy.recordRelaunch()
        #expect(!policy.canRelaunch)
    }

    /// A limit of 0 means "never put it back" — used by nothing yet, but the
    /// arithmetic must not invert.
    @Test func zeroLimitNeverRelaunches() {
        let policy = RelaunchPolicy(limit: 0)
        #expect(!policy.canRelaunch)
        #expect(policy.isExhausted)
    }
}

@Suite struct EscapeHatchTests {
    @Test func firesOnControlOptionCommandQ() {
        #expect(EscapeHatch.matches(modifiers: [.control, .option, .command], characters: "q"))
        #expect(EscapeHatch.matches(modifiers: [.control, .option, .command], characters: "Q"))
        // Shift tolerated.
        #expect(EscapeHatch.matches(modifiers: [.control, .option, .command, .shift], characters: "q"))
    }

    @Test func doesNotFireOnNearMisses() {
        #expect(!EscapeHatch.matches(modifiers: [.command], characters: "q"))
        #expect(!EscapeHatch.matches(modifiers: [.control, .command], characters: "q"))
        #expect(!EscapeHatch.matches(modifiers: [.option, .command], characters: "q"))
        #expect(!EscapeHatch.matches(modifiers: [.control, .option], characters: "q"))
        #expect(!EscapeHatch.matches(modifiers: [], characters: "q"))
        #expect(!EscapeHatch.matches(modifiers: [.control, .option, .command], characters: "w"))
        #expect(!EscapeHatch.matches(modifiers: [.control, .option, .command], characters: nil))
        #expect(!EscapeHatch.matches(modifiers: [.control, .option, .command], characters: ""))
    }

    /// fn+Q can deliver unrelated characters on laptop keyboards.
    @Test func functionKeyBlocksIt() {
        #expect(!EscapeHatch.matches(
            modifiers: [.control, .option, .command, .function],
            characters: "q"
        ))
    }
}

@Suite struct SnapshotFromRecordsTests {
    private let records: [String: ItemRecord] = [
        "m365": ItemRecord(outcome: .success, status: .installed),
        "edge": ItemRecord(outcome: .success, status: .installed),
        "companyportal": ItemRecord(outcome: .skipped, status: .notNeeded),
        "teamviewerqs": ItemRecord(outcome: .failed, status: .downloadFailed),
    ]
    private let ids = ["m365", "edge", "companyportal", "teamviewerqs"]

    /// The bug this exists for: a daemon re-spawned on demand after the marker
    /// was written published "completed" with every item reset to pending, so
    /// the UI read "Your Mac is ready" above "0 of 4 complete".
    @Test func completedRunReportsWhatWasPersisted() {
        let snapshot = ProgressSnapshot.make(
            engineState: .completed,
            itemIDs: ids,
            records: records
        )
        #expect(snapshot.items.map(\.outcome) == [.success, .success, .skipped, .failed])
        #expect(snapshot.completedCount == 3)
        #expect(snapshot.failedCount == 1)
        #expect(snapshot.items.map(\.id) == ids, "configuration order is preserved")
    }

    @Test func unknownItemsFallBackToPending() {
        let snapshot = ProgressSnapshot.make(
            engineState: .running,
            itemIDs: ids + ["brand-new"],
            records: records
        )
        #expect(snapshot.items.last?.outcome == .pending)
        #expect(snapshot.items.last?.status == .waiting)
    }

    @Test func noRecordsYetIsAllPending() {
        let snapshot = ProgressSnapshot.make(engineState: .waitingForConfig, itemIDs: ids, records: [:])
        #expect(snapshot.completedCount == 0)
        #expect(snapshot.items.allSatisfy { $0.outcome == .pending })
    }

    @Test func statusTextsAndDetailRideAlong() {
        let snapshot = ProgressSnapshot.make(
            engineState: .running,
            itemIDs: ["dock"],
            records: ["dock": ItemRecord(outcome: .running, status: .running, detail: ["added": 7])],
            statusTexts: ["dock": "Adding Privileges"]
        )
        #expect(snapshot.items[0].detail["added"] == 7)
        #expect(snapshot.items[0].statusText == "Adding Privileges")
    }
}

@Suite struct UserStateDecodingTests {
    /// A user.json written before `dismissedProvisioningRunAt` existed has
    /// to keep decoding. Failing would lose the user's onboarding progress
    /// and walk them through every step again after an upgrade.
    @Test func aStateFileWithoutTheDismissalFieldStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"items":{},"completedAt":"2026-09-19T06:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(UserState.self, from: Data(json.utf8))
        #expect(state.completedAt != nil)
        #expect(state.dismissedProvisioningRunAt == nil)
    }

    /// Round-trips, so the dismissal actually survives to the next login.
    @Test func theDismissalSurvivesASaveAndLoad() throws {
        let store = StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "user-state-tests-\(UUID().uuidString)"))
        defer { try? store.reset() }

        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try store.saveUserState(UserState(dismissedProvisioningRunAt: when), userName: "someone")
        let loaded = try #require(try store.loadUserState(userName: "someone"))
        #expect(loaded.dismissedProvisioningRunAt == when)
    }
}

@Suite struct DeviceStateDecodingTests {
    /// A device.json written before `preflightFailures` existed has to keep
    /// decoding. Failing would lose the completion marker and re-provision a
    /// Mac that was already finished.
    @Test func aStateFileWithoutThePreflightCountStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"items":{},"completedAt":"2026-09-19T06:00:00Z","lastRunAt":"2026-09-19T05:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(DeviceState.self, from: Data(json.utf8))
        #expect(state.completedAt != nil)
        #expect(state.preflightFailures == 0)
    }

    @Test func thePreflightCountSurvivesASaveAndLoad() throws {
        let store = StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "device-state-tests-\(UUID().uuidString)"))
        defer { try? store.reset() }

        try store.saveDeviceState(DeviceState(preflightFailures: 2))
        #expect(try store.loadDeviceState()?.preflightFailures == 2)
    }
}

@Suite struct UserSessionGateTests {
    private func snapshot(
        _ state: ProgressSnapshot.EngineState,
        startedAt: Date? = Date(timeIntervalSince1970: 1_000)
    ) -> ProgressSnapshot {
        ProgressSnapshot(engineState: state, items: [], startedAt: startedAt)
    }

    /// Provisioning's card is a device progress screen. Once the marker exists
    /// there is nothing for the person at the keyboard to do with it, and a
    /// Mac that has been ready for weeks should not announce it at every
    /// login — which is exactly what it did before.
    @Test func finishedDeviceSaysNothing() {
        #expect(!UserSessionGate.shouldPresent(deviceCompleted: true, provisioning: .nothing))
    }

    /// Someone who logs in mid-provisioning gets a genuine "please wait".
    @Test func unfinishedRunPresents() {
        #expect(UserSessionGate.shouldPresent(deviceCompleted: false, provisioning: .inProgress))
    }

    /// The marker is only written when no required item failed, so a failed
    /// run leaves `deviceCompleted` false and still presents — deliberately.
    @Test func failedRunStillPresents() {
        #expect(UserSessionGate.shouldPresent(deviceCompleted: false, provisioning: .unseenFailure))
    }

    /// The one this was rebuilt for. A permanently failing item means the
    /// marker is never written, and keying on the marker alone opened the
    /// window at every login for the life of the Mac — showing a completed
    /// onboarding with nothing to do in it.
    @Test func aDismissedFailureWithNoWorkLeftSaysNothing() {
        #expect(!UserSessionGate.shouldPresent(
            deviceCompleted: false,
            hasOutstandingUserWork: false,
            provisioning: .nothing
        ))
    }

    /// The gate a user-enrolled VM walked straight through. `requireADE`
    /// refused the Mac, and onboarding then ran anyway and demoted the
    /// account — a real change made by a configuration that had just
    /// declined to touch the Mac at all.
    ///
    /// Nothing is shown either: this Mac was never in scope, and its owner
    /// cannot ADE-enrol it retroactively.
    @Test func anIneligibleMacShowsNothingEvenWithOnboardingOutstanding() {
        #expect(!UserSessionGate.shouldPresent(
            deviceCompleted: false,
            hasOutstandingUserWork: true,
            provisioning: .ineligible
        ))
        #expect(!UserSessionGate.shouldPresent(
            deviceCompleted: false,
            hasOutstandingUserWork: false,
            provisioning: .ineligible
        ))
    }

    /// The flag travels on the snapshot, not the engine state: both ADE and
    /// network failures land on `preflightFailed`, and only one of them bars
    /// onboarding.
    @Test func ineligibilityOutranksADismissalAndIsNotJustPreflightFailed() {
        let ran = Date(timeIntervalSince1970: 1_000)
        let refused = ProgressSnapshot(
            engineState: .preflightFailed, items: [], startedAt: ran, ineligible: true
        )
        // Even if this user dismissed this very run, it is still ineligible.
        #expect(ProvisioningNews(snapshot: refused, dismissedRunAt: ran) == .ineligible)

        let networkFailure = ProgressSnapshot(
            engineState: .preflightFailed, items: [], startedAt: ran, ineligible: false
        )
        #expect(ProvisioningNews(snapshot: networkFailure, dismissedRunAt: ran) == .nothing)
        #expect(ProvisioningNews(snapshot: networkFailure, dismissedRunAt: nil) == .unseenFailure)
    }

    /// Onboarding beats everything: outstanding onboarding work is the whole
    /// reason the user-session UI exists.
    @Test func outstandingUserWorkWins() {
        #expect(UserSessionGate.shouldPresent(
            deviceCompleted: true,
            hasOutstandingUserWork: true,
            provisioning: .nothing
        ))
    }

    // MARK: - Reading the news

    @Test func aRunStillGoingIsInProgress() {
        for state in [ProgressSnapshot.EngineState.waitingForConfig, .preflight, .running] {
            #expect(ProvisioningNews(snapshot: snapshot(state), dismissedRunAt: nil) == .inProgress)
        }
    }

    /// No snapshot at all means the daemon has not published yet — the card
    /// says "connecting" while it starts, rather than the app deciding there
    /// is nothing to show and quitting.
    @Test func nothingPublishedYetIsInProgress() {
        #expect(ProvisioningNews(snapshot: nil, dismissedRunAt: nil) == .inProgress)
    }

    @Test func aCleanRunSaysNothing() {
        #expect(ProvisioningNews(snapshot: snapshot(.completed), dismissedRunAt: nil) == .nothing)
    }

    /// Dismissal is keyed to the run, so the same verdict is not repeated
    /// while a newer one still gets through.
    @Test func aFailureIsNewsUntilThisRunHasBeenDismissed() {
        let ran = Date(timeIntervalSince1970: 1_000)
        let failed = snapshot(.completedWithErrors, startedAt: ran)

        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: nil) == .unseenFailure)
        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: ran) == .nothing)
        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: ran.addingTimeInterval(-60)) == .unseenFailure)
    }

    /// A preflight failure leaves no failed *item* behind, so an
    /// item-counting rule missed it entirely — but the Mac is just as
    /// unprovisioned and the user just as entitled to be told once.
    @Test func aPreflightFailureIsAlsoNews() {
        #expect(ProvisioningNews(snapshot: snapshot(.preflightFailed), dismissedRunAt: nil) == .unseenFailure)
    }
}

@Suite struct DeviceInfoTests {
    /// Every field is optional except the ones we can always get, so the
    /// popover degrades instead of showing "(null)" to a technician.
    @Test func formatsWhatItHasAndOmitsWhatItDoesnt() {
        let full = DeviceInfo(
            marketingName: "MacBook Pro (14-inch, Nov 2023)",
            computerName: "Contoso - MacBook Pro 14 - C02ABC123DEF",
            modelIdentifier: "Mac15,6",
            chip: "Apple M3 Pro",
            memoryBytes: 18 * 1024 * 1024 * 1024,
            storageBytes: 494_384_795_648,
            serialNumber: "C02ABC123DEF",
            osVersion: "macOS 27.0 (26A428)",
            isOnline: true
        )
        #expect(full.memory?.contains("18") == true)
        #expect(full.storage?.contains("494") == true)
        #expect(full.marketingName == "MacBook Pro (14-inch, Nov 2023)")

        let sparse = DeviceInfo(
            computerName: "Mac",
            modelIdentifier: "Mac15,6",
            serialNumber: nil,
            osVersion: "macOS 27.0"
        )
        #expect(sparse.memory == nil)
        #expect(sparse.storage == nil)
        #expect(sparse.marketingName == nil)
        #expect(sparse.isOnline == nil)
    }

    /// Org naming conventions bake the serial into the computer name; printing
    /// it twice makes the line harder to read out loud.
    @Test func summaryDropsADuplicateSerial() {
        let named = DeviceInfo(
            computerName: "Contoso — MacBook Pro 14 — C02ABC123DEF",
            modelIdentifier: "Mac15,6",
            serialNumber: "C02ABC123DEF",
            osVersion: "macOS 27.0"
        )
        #expect(named.summary == "Contoso — MacBook Pro 14 — C02ABC123DEF · Mac15,6 · macOS 27.0")

        let plain = DeviceInfo(
            computerName: "MacBook Air",
            modelIdentifier: "Mac15,13",
            serialNumber: "C304JQC4KM",
            osVersion: "macOS 27.0"
        )
        #expect(plain.summary.contains("C304JQC4KM"))
    }

    /// Reads real hardware: these are the fields the popover leans on, and a
    /// silent nil would only show up in front of a customer.
    @Test func currentDeviceResolvesTheEssentials() {
        let device = DeviceInfo.current()
        #expect(!device.computerName.isEmpty)
        #expect(device.modelIdentifier != "Mac", "hw.model should resolve")
        #expect(device.chip != nil, "machdep.cpu.brand_string should resolve")
        #expect(device.memoryBytes != nil)
        #expect(device.storageBytes != nil)
        #expect(device.osVersion.hasPrefix("macOS "))
        #expect(device.marketingName != nil, "IODeviceTree:/product product-name should resolve")
    }
}

/// Stands in for `/usr/bin/log` being unavailable — as it may well be for
/// `_mbsetupuser` during Setup Assistant.
private struct FailingRunner: ProcessRunning {
    struct Unavailable: Error, LocalizedError {
        var errorDescription: String? { "no such executable" }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        throw Unavailable()
    }
}

@Suite struct LogInspectionTests {
    private func temporaryFile(_ contents: String) throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "logtest-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// install.log is routinely tens of megabytes; a viewer that reads it all
    /// stalls the UI to show boot messages nobody wants.
    @Test func tailReadsTheEndAndDropsAPartialLine() throws {
        let lines = (1...4000).map { "line \($0) padded out to make this file large enough to trim" }
        let url = try temporaryFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = LogInspection.tail(url, maxBytes: 2_000)
        #expect(tail.count <= 2_000)
        #expect(tail.contains("line 4000"))
        #expect(!tail.contains("line 1 padded"), "should have read only the end")
        // The first line must be whole, not a fragment.
        let first = tail.split(separator: "\n").first ?? ""
        #expect(first.hasPrefix("line "), "got a partial line: \(first)")
    }

    @Test func tailOfAMissingFileIsEmptyNotACrash() {
        #expect(LogInspection.tail(URL(filePath: "/var/log/definitely-not-here.log")).isEmpty)
    }

    @Test func summarizeKeepsOnlyMatchingLines() {
        let text = """
        2026-09-17 INFO  : chatty detail nobody needs
        2026-09-17 REQ   : Downloading MicrosoftOfficeBusinessPro
        2026-09-17 INFO  : more chatter
        2026-09-17 REQ   : Installed MicrosoftOfficeBusinessPro
        """
        let summary = LogInspection.summarize(text, patterns: ["REQ"])
        #expect(summary.split(separator: "\n").count == 2)
        #expect(summary.contains("Downloading"))
        #expect(!summary.contains("chatter"))
    }

    /// An already-terse log has no patterns and must come back whole.
    @Test func noPatternsMeansNoFiltering() {
        let text = "one\ntwo\nthree"
        #expect(LogInspection.summarize(text, patterns: []) == text)
    }

    @Test func exportCopiesReadableLogsIntoATimestampedFolder() throws {
        let source = try temporaryFile("hello from the onboarding log")
        defer { try? FileManager.default.removeItem(at: source) }

        let parent = URL(filePath: NSTemporaryDirectory())
            .appending(path: "export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let file = LogFile(id: "t", title: "T", source: .file(source))
        let folder = try LogInspection.export([file], to: parent)

        #expect(folder.lastPathComponent.hasPrefix("IntuneOnboardLogs-"))
        let copied = folder.appending(path: source.lastPathComponent)
        #expect(try String(contentsOf: copied, encoding: .utf8) == "hello from the onboarding log")
    }

    /// Several tabs are views onto install.log; the export must not trip over
    /// copying the same path twice.
    @Test func exportDeduplicatesSharedPaths() throws {
        let source = try temporaryFile("shared")
        defer { try? FileManager.default.removeItem(at: source) }
        let parent = URL(filePath: NSTemporaryDirectory())
            .appending(path: "export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let folder = try LogInspection.export(
            [
                LogFile(id: "a", title: "A", source: .file(source)),
                LogFile(id: "b", title: "B", source: .file(source)),
            ],
            to: parent
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 1)
    }

    @Test func fourTabsWithDistinctIDs() {
        // Our own tab carries the product name, not a stage name: the file it
        // shows covers provisioning and onboarding both.
        #expect(LogFile.all.map(\.title) == ["Intune Onboard", "Installomator", "Installer", "Intune"])
        #expect(Set(LogFile.all.map(\.id)).count == LogFile.all.count)
        #expect(LogFile.app.summaryPatterns.isEmpty, "our own log is already terse")
        // Installomator's own log, not our captured stdout copy: that is the
        // only file with its download progress in it.
        #expect(LogFile.installomator.source == .file(URL(filePath: "/var/log/Installomator.log")))
    }

    // MARK: - Noise

    /// Microsoft's Office packages emit hundreds of these while installing.
    /// They are benign, they contain the word "Error" so the summary kept
    /// every one of them, and on hardware they filled the whole panel.
    @Test func installerNoiseIsDroppedEvenThoughItSaysError() {
        let text = """
        2026-09-17 11:27:16+02:00 Mac installd[512]: IFJS: Package Authoring Error: access to path "/Library/Managed Preferences/com.microsoft.office.plist" requires <options allow-external-scripts='true'>
        2026-09-17 11:27:16+02:00 Mac installd[512]: IFJS: Package Authoring Error: access to path "/Applications/Microsoft Teams.app" requires <options allow-external-scripts='true'>
        2026-09-17 11:27:18+02:00 Mac installd[512]: -[IFDInstallController(Private) _buildInstallPlanReturningError:]: location = file://localhost
        2026-09-17 11:27:20+02:00 Mac installd[512]: Installed "Microsoft Office" ()
        2026-09-17 11:27:21+02:00 Mac installd[512]: Install Failed: Error Domain=PKInstallErrorDomain Code=112
        """
        let cleaned = LogInspection.removeNoise(text, patterns: LogFile.installerNoise)

        #expect(!cleaned.contains("IFJS"))
        #expect(!cleaned.contains("_buildInstallPlanReturningError"))
        #expect(cleaned.contains("Installed \"Microsoft Office\""))
        // The real failure has to survive both filters.
        #expect(cleaned.contains("Install Failed"))
        let summarised = LogInspection.summarize(cleaned, patterns: LogFile.installer.summaryPatterns)
        #expect(summarised.contains("Install Failed"))
        #expect(!summarised.contains("IFJS"))
    }

    @Test func noNoisePatternsLeavesTextAlone() {
        #expect(LogInspection.removeNoise("a\nb", patterns: []) == "a\nb")
    }

    /// Our own pkg install filled the Installer tab with PackageKit's sandbox
    /// plumbing: the sandbox path ends in our bundle id, so those lines
    /// matched the "IntuneOnboard" summary pattern.
    @Test func packageKitSandboxScaffoldingIsDroppedButOutcomesSurvive() {
        let text = """
        2026-09-17 12:02:04+02:00 Mac installd[512]: PackageKit: Executing script "preinstall" in /Library/InstallerSandboxes/.PKInstallSandboxManager/E6FCC341/activeSandbox/Scripts/be.jordythery.intuneonboard.9bWoVD
        2026-09-17 12:02:05+02:00 Mac installd[512]: PackageKit: Parent bundle be.jordythery.intuneonboard will be atomically shoved.
        2026-09-17 12:02:05+02:00 Mac installd[512]: PackageKit: Writing receipt for be.jordythery.intuneonboard to /var/db/receipts
        """
        let cleaned = LogInspection.removeNoise(text, patterns: LogFile.installerNoise)
        #expect(!cleaned.contains("InstallerSandboxes"))
        #expect(!cleaned.contains("atomically shoved"))
        #expect(cleaned.contains("Writing receipt"), "an outcome, not plumbing")
    }

    /// `mobileassetd` logs a multi-line NSError every time it cannot reach
    /// `softwareupdated`, which during Setup Assistant is constantly. Nothing
    /// to do with our installs; each one filled a third of the panel.
    @Test func softwareUpdateDaemonChatterIsDropped() {
        let text = """
        Sep 17 19:15:40 MacBook-Air mobileassetd[111]: SUPreferenceManager: Connection proxy failure with error:Error Domain=NSCocoaErrorDomain Code=4099 "The connection to service named com.apple.softwareupdated was invalidated"
        Sep 17 19:15:40 MacBook-Air mobileassetd[111]: SUPreferenceManager: Failed to get object of required class: NSNumber for key: AutomaticDownload
        Sep 17 19:15:41 MacBook-Air installd[512]: Installed "Microsoft Edge" (141.0)
        """
        let cleaned = LogInspection.removeNoise(text, patterns: LogFile.installerNoise)
        #expect(!cleaned.contains("SUPreferenceManager"))
        #expect(cleaned.contains("Installed \"Microsoft Edge\""))
    }

    /// Intune's agent logs reading a script's stderr *pipe* as "error stream",
    /// twice a second. A healthy enrollment looked like it was failing.
    @Test func intuneErrorStreamBookkeepingIsNotAnError() {
        let text = """
        | IntuneMDM-Daemon | I | 17377 | ScriptOrchestrationLogger | Starting reading error stream ObjectIdentifier(0x9dc849300) State: ScriptEngine.run
        | IntuneMDM-Daemon | I | 17377 | ScriptOrchestrationLogger | Finished reading error stream ObjectIdentifier(0x9dc849300) State: ScriptEngine.run
        | IntuneMDM-Daemon | I | 17384 | SyncActivityRunner | Finished executing sync activity Context: verify enrollment status
        | IntuneMDM-Daemon | E | 17384 | ProfileInstaller | Failed to install profile: timeout
        """
        let cleaned = LogInspection.removeNoise(text, patterns: LogFile.intuneNoise)
        #expect(!cleaned.contains("error stream"))
        #expect(cleaned.contains("verify enrollment status"))
        // The line someone actually opens this tab for.
        #expect(cleaned.contains("Failed to install profile"))
        let summarised = LogInspection.summarize(cleaned, patterns: LogFile.intune.summaryPatterns)
        #expect(summarised.contains("Failed to install profile"))
    }

    // MARK: - Resolving log locations

    /// Intune names each log after the moment it was opened, so the tab has to
    /// find the newest rather than a fixed path.
    @Test func newestFileWinsAcrossDirectories() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "intune-\(UUID().uuidString)")
        let first = root.appending(path: "a")
        let second = root.appending(path: "b")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let old = first.appending(path: "IntuneMDMDaemon 2026-09-01.log")
        let new = second.appending(path: "IntuneMDMDaemon 2026-09-17.log")
        let ignored = second.appending(path: "notes.txt")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try "new".write(to: new, atomically: true, encoding: .utf8)
        try "nope".write(to: ignored, atomically: true, encoding: .utf8)
        // Modification dates decide, not the names in them.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path
        )

        let file = LogFile(
            id: "intune", title: "Intune",
            source: .newest(in: [first, second, root.appending(path: "missing")], extension: "log")
        )
        // Compared by name: the temporary directory is reached through the
        // /var → /private/var symlink, so the URLs differ as strings while
        // naming the same file.
        #expect(file.resolvedURL()?.lastPathComponent == new.lastPathComponent)
    }

    /// Nothing to read is a normal state during provisioning: Intune installs its
    /// agent partway through enrollment.
    @Test func missingLogResolvesToNothingRatherThanAnEmptyPath() {
        let absent = LogFile(
            id: "x", title: "X",
            source: .file(URL(filePath: "/var/log/does-not-exist-\(UUID().uuidString).log"))
        )
        #expect(absent.resolvedURL() == nil)

        let emptyDirectory = LogFile(
            id: "y", title: "Y",
            source: .newest(in: [URL(filePath: "/var/log/no-such-directory-\(UUID().uuidString)")], extension: "log")
        )
        #expect(emptyDirectory.resolvedURL() == nil)
    }

    /// The MDM slice of the unified log is where enrollment actually reports
    /// itself; the export must produce the file even when `log` fails, since
    /// the error is then the finding.
    @Test func mdmCaptureAlwaysWritesAFile() async throws {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "mdm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let written = await LogInspection.captureMDMLog(
            into: folder,
            runner: FailingRunner()
        )
        #expect(written.lastPathComponent == "mdm-unified-log.txt")
        let body = try String(contentsOf: written, encoding: .utf8)
        #expect(body.contains("could not run /usr/bin/log"))
    }

    // MARK: - Line parsing

    /// The clock this Mac would show for an instant — the panel's contract,
    /// so the expectation can't be hard-coded to the test machine's zone.
    private func localClock(of iso: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let date = fractional.date(from: iso) ?? plain.date(from: iso)!

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// Our own format: ISO8601 with milliseconds and a Z.
    @Test func parsesOurISO8601Lines() {
        let lines = LogInspection.lines("2026-09-17T08:53:37.895Z onboardd run starting")
        #expect(lines.count == 1)
        #expect(lines[0].time == localClock(of: "2026-09-17T08:53:37.895Z"))
        #expect(lines[0].message == "onboardd run starting")
        #expect(lines[0].level == .normal)
    }

    /// Our file log writes UTC, which is right for a file and wrong for a
    /// panel read next to Installomator's local times: the Onboarding tab
    /// was two hours off the menu bar, and seven off at the login window
    /// where the Mac's zone isn't set yet.
    @Test func zoneQualifiedTimesAreShownInThisMacsTime() {
        let utc = LogInspection.lines("2026-09-17T08:53:37.895Z onboardd run starting")[0].time
        let offset = LogInspection.lines("2026-09-17T10:53:37.895+02:00 onboardd run starting")[0].time
        #expect(utc == offset, "the same instant in two notations must render identically")

        // Installomator writes no zone; that stamp is already local and is
        // shown exactly as it stands.
        let bare = LogInspection.lines("2026-09-17 01:53:39 : REQ : label : Downloading")[0].time
        #expect(bare == "01:53:39")
    }

    /// Installomator repeats `: LEVEL : label :` on every line; in a narrow
    /// panel that scaffolding would crowd out the message.
    @Test func stripsInstallomatorScaffolding() {
        let lines = LogInspection.lines(
            "2026-09-17 01:53:39 : REQ   : microsoftofficebusinesspro : Downloading https://go.microsoft.com/fwlink"
        )
        #expect(lines[0].time == "01:53:39")
        #expect(lines[0].message == "Downloading https://go.microsoft.com/fwlink")
    }

    @Test func stripsInstallLogProcessPrefix() {
        let lines = LogInspection.lines(
            "2026-09-17 14:51:23+02:00 MacBook-Air installd[561]: PackageKit: Registered bundle"
        )
        #expect(lines[0].time == localClock(of: "2026-09-17T14:51:23+02:00"))
        #expect(lines[0].message == "PackageKit: Registered bundle")
    }

    /// install.log writes an hour-only offset (`+02`, or `-07` on a Mac whose
    /// zone Setup Assistant hasn't set yet). Requiring minutes left a `-07`
    /// at the head of every installer line and defeated the prefix strip, so
    /// the hostname and `installer[pid]:` stayed in the message.
    @Test func hourOnlyZoneOffsetsAreParsed() {
        let lines = LogInspection.lines(
            "2026-09-18 10:03:22-07 L9P-MacBook-Air installer[1434]: PackageKit: Registered bundle"
        )
        #expect(lines[0].time == localClock(of: "2026-09-18T10:03:22-07:00"))
        #expect(lines[0].message == "PackageKit: Registered bundle")
    }

    /// The whole Installer tab came up red because every PackageKit line
    /// mentioning `Microsoft Error Reporting.app` matched a bare "error".
    /// False red is worse than none: nothing stands out any more.
    @Test func thirdPartyLinesAreOnlyRedWhenTheyReallyFail() {
        let benign = LogInspection.lines("""
        2026-09-18 10:03:22-07 air installer[1434]: PackageKit: Registered bundle file:///Applications/OneDrive.app/Contents/SharedSupport/Microsoft%20Error%20Reporting.app/ for uid 0
        2026-09-18 10:03:46-07 air installd[540]: Installed "Microsoft Edge" ()
        """)
        #expect(benign.allSatisfy { $0.level == .normal }, "\(benign.map(\.level))")

        let real = LogInspection.lines("""
        2026-09-18 10:03:22-07 air installer[1434]: Error Domain=NSPOSIXErrorDomain Code=2 "No such file or directory"
        2026-09-18 10:03:22-07 air installer[1434]: failed to open package
        """)
        #expect(real.allSatisfy { $0.level == .error }, "\(real.map(\.level))")
    }

    /// install.log mixes syslog-style lines in with the ISO ones; they were
    /// showing their date, hostname and pid inside the message.
    @Test func syslogStyleLinesAreParsed() {
        let lines = LogInspection.lines(
            "Sep 18 17:22:26 MacBook-Air installd[99]: PackageKit: Writing receipt for our.pkg"
        )
        #expect(lines[0].time == "17:22:26")
        #expect(lines[0].message == "PackageKit: Writing receipt for our.pkg")
    }

    /// An error object carrying code 0 is macOS reporting success in the
    /// shape of a failure.
    @Test func errorObjectsWithCodeZeroAreNotFailures() {
        let lines = LogInspection.lines(
            #"Sep 18 17:22:26 air proc[99]: Created the folder /System/Volumes/Preboot for com.apple.Boot.plist (error Error Domain=NSPOSIXErrorDomain Code=0 "Undefined error: 0")"#
        )
        #expect(lines[0].level == .normal)

        // A real code still reddens.
        let real = LogInspection.lines(
            #"Sep 18 17:25:09 air proc[99]: SUScan: Error encountered in scan: Error Domain=NSURLErrorDomain Code=-1009"#
        )
        #expect(real[0].level == .error)
    }

    /// Our own log gets the benefit of the doubt, because we write it.
    @Test func ourOwnPhrasingStillColours() {
        let ours = LogInspection.lines(
            """
            2026-09-17T08:53:37.895Z item privileges: failed
            2026-09-17T08:53:38.895Z could not record acknowledgement
            2026-09-17T08:53:39.895Z warn endpoint unreachable
            2026-09-17T08:53:40.895Z computer named "L9P-JQC4KM" from template
            """,
            levels: .ourPhrasing
        )
        #expect(ours.map(\.level) == [.error, .error, .warning, .normal])

        // The same wording in a third-party tab only reddens on the hard
        // patterns, and "could not" is not one of them.
        let strict = LogInspection.lines("2026-09-17T08:53:38.895Z could not record acknowledgement")
        #expect(strict[0].level == .normal)
    }

    /// Installomator labels its own lines, and an explicit label always wins
    /// over any reading of the wording. (Phrasing is covered above.)
    @Test func explicitLevelsAreLiftedForColour() {
        let error = LogInspection.lines("2026-09-17 01:53:39 : ERROR : label : could not download")
        #expect(error[0].level == .error)

        let warn = LogInspection.lines("2026-09-17 01:53:40 : WARN  : label : retrying")
        #expect(warn[0].level == .warning)

        let ordinary = LogInspection.lines("2026-09-17 01:53:41 : REQ   : label : Downloading")
        #expect(ordinary[0].level == .normal)
    }

    @Test func blankLinesAreDropped() {
        #expect(LogInspection.lines("\n\n  \n").isEmpty)
    }

    /// A line in no known format still has to render, timestamp or not.
    @Test func unrecognisedLinesSurviveWhole() {
        let lines = LogInspection.lines("################## Start Installomator v. 10.10beta")
        #expect(lines.count == 1)
        #expect(lines[0].time == nil)
        #expect(lines[0].message.contains("Start Installomator"))
    }
}

@Suite struct SetupAssistantPanelTests {
    private func window(
        owner: String,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat,
        height: CGFloat
    ) -> [String: Any] {
        [
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height] as [String: CGFloat],
        ]
    }

    /// A 15-inch Air, the run that exposed the real behaviour: Setup Assistant
    /// owns exactly one window and it is the full-screen backdrop, with the
    /// card it appears to draw being a subview. Matching that window made our
    /// own window full screen and stretched the card across it, so it must
    /// *not* be treated as a panel.
    @Test func setupAssistantsFullScreenBackdropIsNotAPanel() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        #expect(SetupAssistantPanel.frame(
            fromWindowList: [window(owner: "Setup Assistant", x: 0, y: 33, width: 1710, height: 1074)],
            screen: screen
        ) == nil)

        // …and so the window lands card-sized and centred on the backdrop.
        let placed = SetupAssistantPanel.windowFrame(matching: nil, screen: screen)
        #expect(placed.size == SetupAssistantPanel.fallbackSize)
        #expect(placed.midX == 855)
        #expect(placed.midY == 553.5)
    }

    /// Kept for the day a release does give the card its own window.
    @Test func findsACardSizedWindowIfThereIsOne() {
        let frame = SetupAssistantPanel.frame(
            fromWindowList: [
                window(owner: "Finder", width: 1200, height: 800),
                window(owner: "Setup Assistant", x: 320, y: 100, width: 800, height: 600),
            ],
            screen: CGRect(x: 0, y: 0, width: 1710, height: 1107)
        )
        #expect(frame == CGRect(x: 320, y: 100, width: 800, height: 600))
    }

    /// Setup Assistant also draws small helper windows; picking one of those
    /// would be worse than using the fallback.
    @Test func ignoresItsSmallHelperWindows() {
        let frame = SetupAssistantPanel.frame(
            fromWindowList: [
                window(owner: "Setup Assistant", width: 1, height: 1),
                window(owner: "Setup Assistant", width: 120, height: 40),
                window(owner: "Setup Assistant", x: 501, y: 287, width: 798, height: 595),
            ],
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame == CGRect(x: 501, y: 287, width: 798, height: 595))
    }

    /// The largest candidate wins, but only among those that aren't the
    /// backdrop — here the 1700×1000 one is ruled out and the 900×700 chosen.
    @Test func picksTheLargestCandidateThatIsNotTheBackdrop() {
        let frame = SetupAssistantPanel.frame(
            fromWindowList: [
                window(owner: "SetupAssistant", width: 600, height: 400),
                window(owner: "SetupAssistant", width: 900, height: 700),
                window(owner: "SetupAssistant", width: 1700, height: 1000),
            ],
            screen: CGRect(x: 0, y: 0, width: 1710, height: 1107)
        )
        #expect(frame?.size == CGSize(width: 900, height: 700))
    }

    @Test func noSetupAssistantMeansNoAnswer() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        #expect(SetupAssistantPanel.frame(
            fromWindowList: [window(owner: "Finder", width: 1200, height: 800)],
            screen: screen
        ) == nil)
        #expect(SetupAssistantPanel.frame(fromWindowList: [], screen: screen) == nil)
    }

    @Test func malformedEntriesAreSkipped() {
        let frame = SetupAssistantPanel.frame(
            fromWindowList: [
                [kCGWindowOwnerName as String: "Setup Assistant"],  // no bounds
                [kCGWindowBounds as String: ["Width": 800, "Height": 600] as [String: CGFloat]],  // no owner
                [  // no X/Y
                    kCGWindowOwnerName as String: "Setup Assistant",
                    kCGWindowBounds as String: ["Width": 900, "Height": 700] as [String: CGFloat],
                ],
                window(owner: "Setup Assistant", x: 10, y: 20, width: 800, height: 600),
            ],
            screen: CGRect(x: 0, y: 0, width: 1710, height: 1107)
        )
        #expect(frame == CGRect(x: 10, y: 20, width: 800, height: 600))
    }

    /// The census is what the log carries, so the next hardware run records
    /// what Setup Assistant really had on screen instead of leaving it to be
    /// assumed again.
    @Test func censusListsEveryWindowIncludingTheBackdrop() {
        let census = SetupAssistantPanel.setupAssistantWindows(in: [
            window(owner: "Setup Assistant", x: 0, y: 33, width: 1710, height: 1074),
            window(owner: "Setup Assistant", width: 1, height: 1),
            window(owner: "Finder", width: 800, height: 600),
        ])
        #expect(census.count == 2)
        #expect(census.contains(CGRect(x: 0, y: 33, width: 1710, height: 1074)))
    }

    /// Live call against the real window server. Deliberately not asserting
    /// anything about the result: whatever is named "Setup Assistant" on this
    /// machine would be found. What matters is that it answers instead of
    /// crashing.
    @Test func currentFrameAnswersWithoutCrashing() {
        if let frame = SetupAssistantPanel.currentFrame(screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)) {
            #expect(frame.width >= 400)
            #expect(frame.height >= 300)
        }
        #expect(!SetupAssistantPanel.windowCensus().isEmpty)
    }

    // MARK: - Window placement

    /// The 14-inch measurement, which is the one confirmed against a stand-in
    /// panel: CoreGraphics puts the panel 287 pt down from the top, AppKit
    /// wants 287 pt up from the bottom (1169 - 287 - 595).
    @Test func placesTheWindowOnThePanel() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 501, y: 287, width: 798, height: 595),
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame == CGRect(x: 501, y: 287, width: 798, height: 595))
    }

    /// Nothing here is tied to a screen size or a menu bar height, which is
    /// what makes a 16-inch or an Air behave: a panel 40 pt from the top of a
    /// 1000 pt screen is 260 pt from the bottom whatever the machine.
    @Test func placementFollowsTheScreenItIsGiven() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 50, y: 40, width: 800, height: 700),
            screen: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        #expect(frame == CGRect(x: 50, y: 260, width: 800, height: 700))
    }

    /// A panel on a display to the right of the primary one: x passes straight
    /// through, and the flip still uses the primary's height, because that is
    /// what both coordinate systems are anchored to.
    @Test func panelOnASecondDisplayConvertsToo() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 2100, y: 200, width: 800, height: 600),
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame == CGRect(x: 2100, y: 369, width: 800, height: 600))
    }

    /// A panel that isn't centred is still matched exactly — the point is to
    /// coincide with it, not to re-centre it.
    @Test func offCentrePanelsAreMatchedNotRecentred() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 0, y: 0, width: 800, height: 600),
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(frame == CGRect(x: 0, y: 300, width: 800, height: 600))
    }

    /// No Setup Assistant (a user session, the demo): centre the fallback,
    /// which is where it draws its panel anyway.
    @Test func withoutAPanelTheFallbackIsCentred() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: nil,
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame.size == SetupAssistantPanel.fallbackSize)
        #expect(frame.midX == 900)
        #expect(frame.midY == 584.5)
    }
}

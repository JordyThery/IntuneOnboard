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
        try store.saveUserState(state)

        let loaded = try #require(try store.loadUserState())
        #expect(loaded.appliedWallpaperSHA256?.count == 64)

        try store.reset()
        #expect(try store.loadUserState() == nil)
    }

    /// An undecodable file is moved aside and the load throws, rather than
    /// being read as absent (which would discard the completion marker).
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
        // The next load finds no state.
        #expect(try store.loadDeviceState() == nil)
    }
}

@Suite struct RotatingFileSinkTests {
    @Test func rotatesAtLimitAndPrunes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "onboard-log-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appending(path: "onboard.log")

        // 0 MB limit: every write rotates; keep 2 archives.
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
    /// Errors in the requirement string only appear in signed builds.
    @Test func namesBothSigningIdentitiesExactly() {
        let requirement = CodeSigning.peerRequirement(teamIdentifier: "TEAMID1234")
        #expect(requirement.contains("identifier \"be.jordythery.intuneonboard\""))
        #expect(requirement.contains("identifier \"be.jordythery.intuneonboard.daemon\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"TEAMID1234\""))
        #expect(requirement.contains("anchor apple generic"))
    }

    /// `identifier` matches exactly; a trailing `*` would reject every peer.
    @Test func usesNoWildcard() {
        #expect(!CodeSigning.peerRequirement(teamIdentifier: "TEAMID1234").contains("*"))
    }

    @Test func daemonIdentifierIsUnderTheAppIdentifier() {
        // Matches build-pkg.sh's `codesign --identifier`.
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

    /// Suppression takes effect immediately.
    @Test func suppressionWinsAtOnce() {
        var policy = RelaunchPolicy()
        #expect(policy.canRelaunch)
        policy.suppress()
        #expect(!policy.canRelaunch)
        #expect(policy.isSuppressed)
        // Suppressed is not the same as exhausted.
        #expect(!policy.isExhausted)
    }

    @Test func suppressionIsIdempotentAndFinal() {
        var policy = RelaunchPolicy()
        policy.suppress()
        policy.suppress()
        policy.recordRelaunch()
        #expect(!policy.canRelaunch)
    }

    /// A limit of 0 never relaunches.
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
        // Shift allowed.
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

    /// fn is not allowed.
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

    /// A completed run keeps its item records when republished.
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
    /// Older user.json files without `dismissedProvisioningRunAt` still decode.
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

    /// The dismissal is saved.
    @Test func theDismissalSurvivesASaveAndLoad() throws {
        let store = StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "user-state-tests-\(UUID().uuidString)"))
        defer { try? store.reset() }

        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try store.saveUserState(UserState(dismissedProvisioningRunAt: when))
        let loaded = try #require(try store.loadUserState())
        #expect(loaded.dismissedProvisioningRunAt == when)
    }
}

@Suite struct DeviceStateDecodingTests {
    /// Older device.json files without `preflightFailures` still decode.
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

    /// A completed Mac with no onboarding work shows nothing.
    @Test func finishedDeviceSaysNothing() {
        #expect(!UserSessionGate.shouldPresent(deviceCompleted: true, provisioning: .nothing))
    }

    /// A run in progress is shown.
    @Test func unfinishedRunPresents() {
        #expect(UserSessionGate.shouldPresent(deviceCompleted: false, provisioning: .inProgress))
    }

    /// A failed run is shown.
    @Test func failedRunStillPresents() {
        #expect(UserSessionGate.shouldPresent(deviceCompleted: false, provisioning: .unseenFailure))
    }

    /// A failure already dismissed is not shown again.
    @Test func aDismissedFailureWithNoWorkLeftSaysNothing() {
        #expect(!UserSessionGate.shouldPresent(
            deviceCompleted: false,
            hasOutstandingUserWork: false,
            provisioning: .nothing
        ))
    }

    /// An ineligible Mac shows nothing, even with onboarding configured.
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

    /// Ineligibility is a snapshot flag, separate from `preflightFailed`.
    @Test func ineligibilityOutranksADismissalAndIsNotJustPreflightFailed() {
        let ran = Date(timeIntervalSince1970: 1_000)
        let refused = ProgressSnapshot(
            engineState: .preflightFailed, items: [], startedAt: ran, ineligible: true
        )
        // Dismissal does not change ineligibility.
        #expect(ProvisioningNews(snapshot: refused, dismissedRunAt: ran) == .ineligible)

        let networkFailure = ProgressSnapshot(
            engineState: .preflightFailed, items: [], startedAt: ran, ineligible: false
        )
        #expect(ProvisioningNews(snapshot: networkFailure, dismissedRunAt: ran) == .nothing)
        #expect(ProvisioningNews(snapshot: networkFailure, dismissedRunAt: nil) == .unseenFailure)
    }

    /// Outstanding onboarding is always shown.
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

    /// No snapshot yet counts as in progress.
    @Test func nothingPublishedYetIsInProgress() {
        #expect(ProvisioningNews(snapshot: nil, dismissedRunAt: nil) == .inProgress)
    }

    @Test func aCleanRunSaysNothing() {
        #expect(ProvisioningNews(snapshot: snapshot(.completed), dismissedRunAt: nil) == .nothing)
    }

    /// Dismissal applies to one run; a newer failure is shown.
    @Test func aFailureIsNewsUntilThisRunHasBeenDismissed() {
        let ran = Date(timeIntervalSince1970: 1_000)
        let failed = snapshot(.completedWithErrors, startedAt: ran)

        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: nil) == .unseenFailure)
        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: ran) == .nothing)
        #expect(ProvisioningNews(snapshot: failed, dismissedRunAt: ran.addingTimeInterval(-60)) == .unseenFailure)
    }

    /// A preflight failure counts as a failure.
    @Test func aPreflightFailureIsAlsoNews() {
        #expect(ProvisioningNews(snapshot: snapshot(.preflightFailed), dismissedRunAt: nil) == .unseenFailure)
    }
}

@Suite struct DeviceInfoTests {
    /// Missing fields are omitted, not shown as "(null)".
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

    /// The serial is omitted when the computer name contains it.
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

    /// Reads the real device.
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

/// Simulates `/usr/bin/log` being unavailable.
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

    /// Only the end of a large file is read.
    @Test func tailReadsTheEndAndDropsAPartialLine() throws {
        let lines = (1...4000).map { "line \($0) padded out to make this file large enough to trim" }
        let url = try temporaryFile(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = LogInspection.tail(url, maxBytes: 2_000)
        #expect(tail.count <= 2_000)
        #expect(tail.contains("line 4000"))
        #expect(!tail.contains("line 1 padded"), "should have read only the end")
        // The first line is complete.
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

    /// No patterns returns the whole text.
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

    /// Export copies a file shared by several tabs once.
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
        // Covers both stages.
        #expect(LogFile.all.map(\.title) == ["Intune Onboard", "Installomator", "Installer", "Intune"])
        #expect(Set(LogFile.all.map(\.id)).count == LogFile.all.count)
        #expect(LogFile.app.summaryPatterns.isEmpty, "our own log is already terse")
        // Installomator's own log file.
        #expect(LogFile.installomator.source == .file(URL(filePath: "/var/log/Installomator.log")))
    }

    // MARK: - Noise

    /// Hides Microsoft's benign "Package Authoring Error" lines.
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
        // Real failures remain.
        #expect(cleaned.contains("Install Failed"))
        let summarised = LogInspection.summarize(cleaned, patterns: LogFile.installer.summaryPatterns)
        #expect(summarised.contains("Install Failed"))
        #expect(!summarised.contains("IFJS"))
    }

    @Test func noNoisePatternsLeavesTextAlone() {
        #expect(LogInspection.removeNoise("a\nb", patterns: []) == "a\nb")
    }

    /// Hides PackageKit sandbox lines, which contain this app's bundle id.
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

    /// Hides mobileassetd's softwareupdated connection errors.
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

    /// Hides Intune's routine "error stream" lines.
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
        // Real failures remain.
        #expect(cleaned.contains("Failed to install profile"))
        let summarised = LogInspection.summarize(cleaned, patterns: LogFile.intune.summaryPatterns)
        #expect(summarised.contains("Failed to install profile"))
    }

    // MARK: - Resolving log locations

    /// The newest Intune log is chosen.
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
        // By modification date, not name.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path
        )

        let file = LogFile(
            id: "intune", title: "Intune",
            source: .newest(in: [first, second, root.appending(path: "missing")], extension: "log")
        )
        // Compared by name: /var and /private/var differ as strings.
        #expect(file.resolvedURL()?.lastPathComponent == new.lastPathComponent)
    }

    /// A missing Intune log is not an error.
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

    /// The MDM log file is written even when `log` fails.
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

    /// The expected local time, independent of the test machine's zone.
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

    /// ISO 8601 with milliseconds and Z.
    @Test func parsesOurISO8601Lines() {
        let lines = LogInspection.lines("2026-09-17T08:53:37.895Z onboardd run starting")
        #expect(lines.count == 1)
        #expect(lines[0].time == localClock(of: "2026-09-17T08:53:37.895Z"))
        #expect(lines[0].message == "onboardd run starting")
        #expect(lines[0].level == .normal)
    }

    /// UTC times are shown in local time.
    @Test func zoneQualifiedTimesAreShownInThisMacsTime() {
        let utc = LogInspection.lines("2026-09-17T08:53:37.895Z onboardd run starting")[0].time
        let offset = LogInspection.lines("2026-09-17T10:53:37.895+02:00 onboardd run starting")[0].time
        #expect(utc == offset, "the same instant in two notations must render identically")

        // Installomator times have no zone and are shown unchanged.
        let bare = LogInspection.lines("2026-09-17 01:53:39 : REQ : label : Downloading")[0].time
        #expect(bare == "01:53:39")
    }

    /// Installomator's `: LEVEL : label :` prefix is removed.
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

    /// Hour-only offsets (`+02`, `-07`) are parsed.
    @Test func hourOnlyZoneOffsetsAreParsed() {
        let lines = LogInspection.lines(
            "2026-09-18 10:03:22-07 L9P-MacBook-Air installer[1434]: PackageKit: Registered bundle"
        )
        #expect(lines[0].time == localClock(of: "2026-09-18T10:03:22-07:00"))
        #expect(lines[0].message == "PackageKit: Registered bundle")
    }

    /// Paths containing "Error" do not mark a line as an error.
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

    /// Syslog-style lines are parsed.
    @Test func syslogStyleLinesAreParsed() {
        let lines = LogInspection.lines(
            "Sep 18 17:22:26 MacBook-Air installd[99]: PackageKit: Writing receipt for our.pkg"
        )
        #expect(lines[0].time == "17:22:26")
        #expect(lines[0].message == "PackageKit: Writing receipt for our.pkg")
    }

    /// Errors with code 0 are not errors.
    @Test func errorObjectsWithCodeZeroAreNotFailures() {
        let lines = LogInspection.lines(
            #"Sep 18 17:22:26 air proc[99]: Created the folder /System/Volumes/Preboot for com.apple.Boot.plist (error Error Domain=NSPOSIXErrorDomain Code=0 "Undefined error: 0")"#
        )
        #expect(lines[0].level == .normal)

        // A non-zero code is.
        let real = LogInspection.lines(
            #"Sep 18 17:25:09 air proc[99]: SUScan: Error encountered in scan: Error Domain=NSURLErrorDomain Code=-1009"#
        )
        #expect(real[0].level == .error)
    }

    /// This app's wording marks errors in its own log.
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

        // In other logs only explicit markers count.
        let strict = LogInspection.lines("2026-09-17T08:53:38.895Z could not record acknowledgement")
        #expect(strict[0].level == .normal)
    }

    /// Installomator's level label takes precedence.
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

    /// Lines in unknown formats are kept.
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

    /// A full-screen Setup Assistant window is the backdrop, not a panel.
    @Test func setupAssistantsFullScreenBackdropIsNotAPanel() {
        let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        #expect(SetupAssistantPanel.frame(
            fromWindowList: [window(owner: "Setup Assistant", x: 0, y: 33, width: 1710, height: 1074)],
            screen: screen
        ) == nil)

        // The window is the fallback size, centred.
        let placed = SetupAssistantPanel.windowFrame(matching: nil, screen: screen)
        #expect(placed.size == SetupAssistantPanel.fallbackSize)
        #expect(placed.midX == 855)
        #expect(placed.midY == 553.5)
    }

    /// A card-sized Setup Assistant window is matched.
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

    /// Small helper windows are ignored.
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

    /// The largest non-backdrop window wins.
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

    /// The census lists Setup Assistant's windows, for the log.
    @Test func censusListsEveryWindowIncludingTheBackdrop() {
        let census = SetupAssistantPanel.setupAssistantWindows(in: [
            window(owner: "Setup Assistant", x: 0, y: 33, width: 1710, height: 1074),
            window(owner: "Setup Assistant", width: 1, height: 1),
            window(owner: "Finder", width: 800, height: 600),
        ])
        #expect(census.count == 2)
        #expect(census.contains(CGRect(x: 0, y: 33, width: 1710, height: 1074)))
    }

    /// Queries the real window server; only checks that it returns.
    @Test func currentFrameAnswersWithoutCrashing() {
        if let frame = SetupAssistantPanel.currentFrame(screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)) {
            #expect(frame.width >= 400)
            #expect(frame.height >= 300)
        }
        #expect(!SetupAssistantPanel.windowCensus().isEmpty)
    }

    // MARK: - Window placement

    /// Converts a measured panel: 287 pt from the top becomes 287 pt from
    /// the bottom (1169 − 287 − 595).
    @Test func placesTheWindowOnThePanel() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 501, y: 287, width: 798, height: 595),
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame == CGRect(x: 501, y: 287, width: 798, height: 595))
    }

    /// Independent of screen size and menu bar height.
    @Test func placementFollowsTheScreenItIsGiven() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 50, y: 40, width: 800, height: 700),
            screen: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        #expect(frame == CGRect(x: 50, y: 260, width: 800, height: 700))
    }

    /// A panel on a second display: x unchanged, y flipped using the
    /// primary display's height.
    @Test func panelOnASecondDisplayConvertsToo() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 2100, y: 200, width: 800, height: 600),
            screen: CGRect(x: 0, y: 0, width: 1800, height: 1169)
        )
        #expect(frame == CGRect(x: 2100, y: 369, width: 800, height: 600))
    }

    /// Off-centre panels are matched exactly.
    @Test func offCentrePanelsAreMatchedNotRecentred() {
        let frame = SetupAssistantPanel.windowFrame(
            matching: CGRect(x: 0, y: 0, width: 800, height: 600),
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(frame == CGRect(x: 0, y: 300, width: 800, height: 600))
    }

    /// Without Setup Assistant, the fallback size is centred.
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

import Foundation
import Testing
@testable import OnboardCore

/// A mutable stand-in for the system, changed between evaluations.
private final class FakeSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var _wallpaper: String?
    private var _defaults: [DefaultAppTarget: String] = [:]
    private var _admins: Set<String> = []
    private var _files: Set<String> = []
    var user = "jordy"

    func with<T>(_ body: (FakeSystem) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    var wallpaper: String? {
        get { lock.lock(); defer { lock.unlock() }; return _wallpaper }
        set { lock.lock(); defer { lock.unlock() }; _wallpaper = newValue }
    }
    subscript(target: DefaultAppTarget) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return _defaults[target] }
        set { lock.lock(); defer { lock.unlock() }; _defaults[target] = newValue }
    }
    func setAdmin(_ name: String, _ isAdmin: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isAdmin { _admins.insert(name) } else { _admins.remove(name) }
    }
    func isAdmin(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _admins.contains(name) }
    func addFile(_ path: String) { lock.lock(); defer { lock.unlock() }; _files.insert(path) }
    func fileExists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _files.contains(path) }

    var probes: OnboardingProbes {
        OnboardingProbes(
            currentUserName: { [self] in user },
            fileExists: { [self] in fileExists($0) },
            currentWallpaperPath: { [self] in wallpaper },
            currentDefaultApp: { [self] in self[$0] },
            isMemberOfAdminGroup: { [self] in isAdmin($0) }
        )
    }
}

/// Scripted action results, recording each request.
private final class FakeActions: OnboardingActing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: ItemRecord] = [:]
    private(set) var performed: [(id: String, choice: StepChoice?)] = []

    func stub(_ id: String, _ record: ItemRecord) {
        lock.lock(); defer { lock.unlock() }
        results[id] = record
    }

    func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord {
        lock.withLock {
            performed.append((item.id, choice))
            return results[item.id] ?? ItemRecord(outcome: .success, status: .done)
        }
    }
}

@Suite struct OnboardingDerivationTests {
    private let system = FakeSystem()

    @Test func defaultAppsAutoCompletesWhenEverythingAlreadyMatches() async {
        system[.browser] = "com.microsoft.edgemac"
        system[.scheme("mailto")] = "com.apple.mail"
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            urlSchemes: ["mailto": ["com.microsoft.Outlook", "com.apple.mail"]]
        )))
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)

        // …and becomes incomplete when the system changes back.
        system[.browser] = "com.apple.Safari"
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .suggested)
    }

    /// A success record does not complete `defaultApps` while the handler is
    /// unchanged; the user may have declined the prompt. Keeping the current
    /// handler (skipped) does.
    @Test func defaultAppsSuccessRecordDoesNotBeatAnUnchangedHandler() async {
        system[.browser] = "com.apple.Safari"
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            allowKeepExisting: true
        )))

        let claimedSuccess = ItemRecord(outcome: .success, status: .done)
        #expect(await OnboardingDerivation.status(of: item, record: claimedSuccess, probes: system.probes) == .suggested)

        let keptCurrent = ItemRecord(outcome: .skipped, status: .notNeeded)
        #expect(await OnboardingDerivation.status(of: item, record: keptCurrent, probes: system.probes) == .completed)

        // Once the handler changes, the step is complete.
        system[.browser] = "com.microsoft.edgemac"
        #expect(await OnboardingDerivation.status(of: item, record: claimedSuccess, probes: system.probes) == .completed)
    }

    /// Targets with no installed candidates are ignored; if all are, the
    /// step is complete.
    @Test func uninstalledCandidatesNeverHoldTheStepHostage() async {
        system[.browser] = "com.microsoft.edgemac"
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            urlSchemes: ["mailto": ["com.notinstalled.mail"]]
        )))

        var probes = system.probes
        probes.isAppInstalled = { $0 == "com.microsoft.edgemac" }
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: probes) == .completed,
                "the absent mailto candidate must not block the matching browser")

        probes.isAppInstalled = { _ in false }
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: probes) == .completed,
                "a step with nothing installed is auto-skipped, not stuck")
    }

    @Test func demotionIsJudgedByMembershipNotByRecords() async {
        let item = OnboardingItem(id: "demote", kind: .demoteUser(exclude: ["ladmin"]))
        system.setAdmin("jordy", true)

        // Admin membership outweighs a success record.
        let staleSuccess = ItemRecord(outcome: .success, status: .done)
        #expect(await OnboardingDerivation.status(of: item, record: staleSuccess, probes: system.probes) == .suggested)

        system.setAdmin("jordy", false)
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)
    }

    @Test func excludedUserIsNeverSuggestedForDemotion() async {
        system.user = "ladmin"
        system.setAdmin("ladmin", true)
        let item = OnboardingItem(id: "demote", kind: .demoteUser(exclude: ["ladmin"]))
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)
    }

    @Test func wallpaperCompletesWhenTheCurrentWallpaperIsOurs() async {
        let spec = OnboardingItem.WallpaperSpec(sources: [
            .remote(URL(string: "https://example.com/a.jpg")!),
            .path("/Library/Desktop Pictures/corp.jpg"),
        ])
        let item = OnboardingItem(id: "w", kind: .wallpaper(spec))

        system.wallpaper = "/System/Library/Desktop Pictures/Sequoia.heic"
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .suggested)

        system.wallpaper = "/Library/Desktop Pictures/corp.jpg"
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)

        system.wallpaper = WallpaperLocation.destination(for: spec.sources[0]).path
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)
    }

    /// Remote sources with the same file name get different local paths.
    @Test func remoteDestinationsCannotCollide() {
        let first = WallpaperLocation.destination(for: .remote(URL(string: "https://a.example/w.jpg")!))
        let second = WallpaperLocation.destination(for: .remote(URL(string: "https://b.example/w.jpg")!))
        #expect(first != second)
        #expect(first.lastPathComponent.hasSuffix("-w.jpg"))
    }

    @Test func openWithValidatePathIsMeasuredNotTakenOnTrust() async {
        let item = OnboardingItem(
            id: "o",
            kind: .open(target: .bundleID("com.microsoft.CompanyPortalMac"), completion: .validatePath),
            validatePath: "/var/db/enrolled"
        )
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .suggested)
        system.addFile("/var/db/enrolled")
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)
    }

    @Test func disabledItemsAreCompleteWithoutRunning() async {
        let item = OnboardingItem(id: "x", kind: .dock(.init(items: [])), enabled: false)
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .completed)
    }
}

@Suite struct OnboardingEngineTests {
    private let system = FakeSystem()
    private let actions = FakeActions()

    private func makeStore() throws -> StateStore {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StateStore(rootDirectory: directory)
    }

    @Test func alreadySatisfiedStepsGetASkippedRecordSoTheMarkerLogicSeesThem() async throws {
        system[.browser] = "com.microsoft.edgemac"
        let store = try makeStore()
        let engine = OnboardingEngine(
            items: [OnboardingItem(id: "d", kind: .defaultApps(.init(browsers: ["com.microsoft.edgemac"])))],
            store: store,
            probes: system.probes,
            actions: actions
        )

        let states = await engine.refresh()
        #expect(states[0].status == .completed)
        #expect(states[0].record?.outcome == .skipped)
        #expect(states[0].record?.status == .notNeeded)

        // All required steps complete: the marker is written.
        let saved = try store.loadUserState()
        #expect(saved?.completedAt != nil)
    }

    @Test func performRoutesToTheActionAndReDerives() async throws {
        system.setAdmin("jordy", true)
        let store = try makeStore()
        let engine = OnboardingEngine(
            items: [OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))],
            store: store,
            probes: system.probes,
            actions: actions
        )
        #expect(await engine.refresh()[0].status == .suggested)

        // The action removes the user from the admin group.
        actions.stub("demote", ItemRecord(outcome: .success, status: .done))
        system.setAdmin("jordy", false)
        let states = await engine.perform(itemID: "demote")

        #expect(actions.performed.map(\.id) == ["demote"])
        #expect(states[0].status == .completed)
        #expect(try store.loadUserState()?.items["demote"]?.outcome == .success)
    }

    @Test func choicesReachTheAction() async throws {
        let engine = OnboardingEngine(
            items: [OnboardingItem(id: "dock", kind: .dock(.init(strategies: [.add, .replace], items: [])))],
            store: try makeStore(),
            probes: system.probes,
            actions: actions
        )
        _ = await engine.perform(itemID: "dock", choice: .dock(.replace))
        #expect(actions.performed.first?.choice == .dock(.replace))
    }

    /// A message step completes once viewed.
    @Test func messageStepsCompleteOnceViewed() async throws {
        let engine = OnboardingEngine(
            items: [OnboardingItem(id: "welcome", kind: .message, required: false)],
            store: try makeStore(),
            probes: system.probes,
            actions: actions
        )
        #expect(await engine.refresh()[0].status == .suggested)
        let states = await engine.perform(itemID: "welcome")
        #expect(states[0].status == .completed)
    }

    @Test func markDoneOnlyBelievesTheUserForManualOpenSteps() async throws {
        let store = try makeStore()
        system.setAdmin("jordy", true)
        let engine = OnboardingEngine(
            items: [
                OnboardingItem(id: "portal", kind: .open(target: .bundleID("x"), completion: .manual)),
                OnboardingItem(id: "demote", kind: .demoteUser(exclude: [])),
            ],
            store: store,
            probes: system.probes,
            actions: actions
        )

        var states = await engine.markDone(itemID: "portal")
        #expect(states.first { $0.id == "portal" }?.status == .completed)

        // markDone is refused for measured kinds.
        states = await engine.markDone(itemID: "demote")
        #expect(states.first { $0.id == "demote" }?.status == .suggested)
        #expect(try store.loadUserState()?.items["demote"]?.outcome != .success)
    }

    @Test func markerWaitsForRequiredStepsAndIsWrittenOnce() async throws {
        system.setAdmin("jordy", true)
        let store = try makeStore()
        let engine = OnboardingEngine(
            items: [
                OnboardingItem(id: "demote", kind: .demoteUser(exclude: []), required: true),
                OnboardingItem(id: "portal", kind: .open(target: .bundleID("x"), completion: .manual), required: false),
            ],
            store: store,
            probes: system.probes,
            actions: actions
        )

        _ = await engine.refresh()
        #expect(try store.loadUserState()?.completedAt == nil, "an admin user means the required step is open")

        system.setAdmin("jordy", false)
        _ = await engine.refresh()
        let completedAt = try store.loadUserState()?.completedAt
        #expect(completedAt != nil, "the optional step cannot hold the marker hostage")

        // A later refresh keeps the timestamp.
        try await Task.sleep(for: .milliseconds(20))
        _ = await engine.refresh()
        #expect(try store.loadUserState()?.completedAt == completedAt)
    }
}

/// The `focus` backdrop is lifted only for apps onboarding opened.
@Suite @MainActor struct FocusExemptionTests {
    @Test func liftsOnlyForAppsTheOnboardingLaunched() {
        FocusExemptions.removeAll()
        FocusExemptions.allow("com.microsoft.CompanyPortalMac")

        #expect(FocusExemptions.allowsBackdropLift(for: "com.microsoft.CompanyPortalMac"))
        // An app the user opened stays covered…
        #expect(!FocusExemptions.allowsBackdropLift(for: "com.apple.Safari"))
        // …and returning to this app restores the backdrop.
        #expect(!FocusExemptions.allowsBackdropLift(for: "be.jordythery.intuneonboard"))
        #expect(!FocusExemptions.allowsBackdropLift(for: nil))
        FocusExemptions.removeAll()
    }

    @Test func emptyAndMissingBundleIDsAreIgnored() {
        FocusExemptions.removeAll()
        FocusExemptions.allow(nil)
        FocusExemptions.allow("")
        #expect(FocusExemptions.bundleIDs.isEmpty)
        #expect(!FocusExemptions.allowsBackdropLift(for: ""))
    }

    /// The exemption is by app, not by step status: an `open` step is
    /// complete as soon as the launch succeeds.
    @Test func anOpenStepCompletesAsSoonAsItLaunches() async {
        let item = OnboardingItem(
            id: "portal",
            kind: .open(target: .bundleID("com.microsoft.CompanyPortalMac"), completion: .manual)
        )
        let launched = ItemRecord(outcome: .success, status: .awaitingUser)
        let status = await OnboardingDerivation.status(
            of: item,
            record: launched,
            probes: OnboardingProbes(
                currentUserName: { "jordy" },
                fileExists: { _ in false },
                currentWallpaperPath: { nil },
                currentDefaultApp: { _ in nil },
                isMemberOfAdminGroup: { _ in false }
            )
        )
        #expect(status == .completed)
    }
}

/// Dry-run onboarding: changes go to the overlay; the real system is unchanged.
@Suite struct DryRunOnboardingTests {
    private let system = FakeSystem()

    private func makeDryRun() -> (world: DryRunOnboardingWorld, actions: DryRunOnboardingActions) {
        let world = DryRunOnboardingWorld(base: system.probes)
        return (world, DryRunOnboardingActions(world: world, sleep: { _ in }))
    }

    @Test func defaultAppsOverlayCompletesTheStepWithoutTouchingTheSystem() async {
        system[.browser] = "com.apple.Safari"
        let (world, actions) = makeDryRun()
        let item = OnboardingItem(id: "browser", kind: .defaultApps(.init(browsers: ["com.microsoft.edgemac"])))

        let record = await actions.perform(item, choice: nil)
        #expect(record.outcome == .success)
        #expect(record.message == "dry run — simulated")

        // Evaluation through the overlay sees the change…
        let status = await OnboardingDerivation.status(of: item, record: record, probes: world.probes)
        #expect(status == .completed)
        // …while the real system is unchanged.
        #expect(system[.browser] == "com.apple.Safari")
    }

    @Test func demotionOverlayNeverReachesTheAdminGroup() async {
        system.setAdmin("jordy", true)
        let (world, actions) = makeDryRun()
        let item = OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))

        let record = await actions.perform(item, choice: nil)
        #expect(record.outcome == .success)
        let status = await OnboardingDerivation.status(of: item, record: record, probes: world.probes)
        #expect(status == .completed)
        #expect(system.isAdmin("jordy"), "the dry run demoted the overlay, not the user")
    }

    @Test func openStepTouchesOnlyTheOverlayAndLaunchesNothing() async {
        let (world, actions) = makeDryRun()
        let item = OnboardingItem(
            id: "portal",
            kind: .open(target: .bundleID("com.microsoft.CompanyPortalMac"), completion: .validatePath),
            validatePath: "/var/db/enrolled"
        )

        let record = await actions.perform(item, choice: nil)
        #expect(record.outcome == .success)
        #expect(record.message == "dry run — not opened")
        let status = await OnboardingDerivation.status(of: item, record: record, probes: world.probes)
        #expect(status == .completed)
        #expect(!system.fileExists("/var/db/enrolled"))
    }

    @Test func keepCurrentAndMissingWallpaperKeepTheRealRulesInDryRun() async {
        let (world, actions) = makeDryRun()

        // keepCurrent is not simulated.
        let dock = OnboardingItem(id: "dock", kind: .dock(.init(strategies: [.add, .keep], items: [])))
        let kept = await actions.perform(dock, choice: .keepCurrent)
        #expect(kept.outcome == .skipped)

        // A missing local wallpaper is skipped.
        let wallpaper = OnboardingItem(id: "wp", kind: .wallpaper(.init(sources: [.path("/nonexistent/corp.jpg")])))
        let skipped = await actions.perform(wallpaper, choice: nil)
        #expect(skipped.outcome == .skipped)

        // Remote sources are assumed downloaded.
        let url = URL(string: "https://example.com/corp.jpg")!
        let remote = OnboardingItem(id: "wp2", kind: .wallpaper(.init(sources: [.remote(url)])))
        let record = await actions.perform(remote, choice: nil)
        #expect(record.outcome == .success)
        let status = await OnboardingDerivation.status(of: remote, record: record, probes: world.probes)
        #expect(status == .completed)
    }
}

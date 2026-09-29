import Foundation
import Testing
@testable import OnboardCore

/// Mutable system stand-in: tests flip these to simulate the user (or an
/// action) changing the system between derivations.
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

/// Scripted action results, recording what it was asked to do.
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

        // …and un-completes the moment the system stops matching.
        system[.browser] = "com.apple.Safari"
        #expect(await OnboardingDerivation.status(of: item, record: nil, probes: system.probes) == .suggested)
    }

    /// utiluti exiting 0 only means the request was made — the user can still
    /// decline macOS's own prompt (seen on hardware). A success record with an
    /// unchanged handler must NOT complete the step; "keep current" (skipped)
    /// is the one recorded outcome that counts, being a decision rather than
    /// a claim about the system.
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

        // The moment the system really changes, the same success record reads
        // as completed — measured, not taken on trust.
        system[.browser] = "com.microsoft.edgemac"
        #expect(await OnboardingDerivation.status(of: item, record: claimedSuccess, probes: system.probes) == .completed)
    }

    /// Candidates that aren't installed neither block nor count: a target
    /// with none of its apps present is ignored outright, and a step whose
    /// every target is absent derives completed.
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

        // A stale success record does not beat the fact the user is an admin.
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

    /// Two remote sources with the same basename must not share a local file.
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

        // Everything required is complete, so the marker lands.
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

        // The action's side effect: the user leaves the admin group.
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

    /// A message step completes by being seen: the auto-perform records it,
    /// derivation reads the record, Continue lights.
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

        // markDone on a measured kind is refused: the user's word does not
        // demote anybody.
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

        // A later refresh must not move the timestamp.
        try await Task.sleep(for: .milliseconds(20))
        _ = await engine.refresh()
        #expect(try store.loadUserState()?.completedAt == completedAt)
    }
}

/// `windowPosition: focus` must not strand the app it just sent the user to,
/// and must not excuse anything else.
@Suite @MainActor struct FocusExemptionTests {
    @Test func liftsOnlyForAppsTheOnboardingLaunched() {
        FocusExemptions.removeAll()
        FocusExemptions.allow("com.microsoft.CompanyPortalMac")

        #expect(FocusExemptions.allowsBackdropLift(for: "com.microsoft.CompanyPortalMac"))
        // A browser the user started themselves stays covered…
        #expect(!FocusExemptions.allowsBackdropLift(for: "com.apple.Safari"))
        // …and returning to our own window brings the backdrop back.
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

    /// The rule that replaced the first attempt: an `open` step's record
    /// reads completed the instant the launch succeeds, so watching for a
    /// "waiting on the user" step never lifted anything.
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

/// The profile's DEBUG key, onboarding side: actions land in the overlay,
/// derivation reads through it, the real system stays exactly as it was.
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
        #expect(record.message == "DEBUG — simulated")

        // Derivation through the overlay sees the change and completes…
        let status = await OnboardingDerivation.status(of: item, record: record, probes: world.probes)
        #expect(status == .completed)
        // …while the "real Mac" never changed.
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
        #expect(record.message == "DEBUG — not opened")
        let status = await OnboardingDerivation.status(of: item, record: record, probes: world.probes)
        #expect(status == .completed)
        #expect(!system.fileExists("/var/db/enrolled"))
    }

    @Test func keepCurrentAndMissingWallpaperKeepTheRealRulesInDryRun() async {
        let (world, actions) = makeDryRun()

        // keepCurrent stays a decision, not a simulation.
        let dock = OnboardingItem(id: "dock", kind: .dock(.init(strategies: [.add, .keep], items: [])))
        let kept = await actions.perform(dock, choice: .keepCurrent)
        #expect(kept.outcome == .skipped)

        // A local wallpaper file that isn't there skips, same as for real.
        let wallpaper = OnboardingItem(id: "wp", kind: .wallpaper(.init(sources: [.path("/nonexistent/corp.jpg")])))
        let skipped = await actions.perform(wallpaper, choice: nil)
        #expect(skipped.outcome == .skipped)

        // A remote source presumes its download and completes via the overlay.
        let url = URL(string: "https://example.com/corp.jpg")!
        let remote = OnboardingItem(id: "wp2", kind: .wallpaper(.init(sources: [.remote(url)])))
        let record = await actions.perform(remote, choice: nil)
        #expect(record.outcome == .success)
        let status = await OnboardingDerivation.status(of: remote, record: record, probes: world.probes)
        #expect(status == .completed)
    }
}

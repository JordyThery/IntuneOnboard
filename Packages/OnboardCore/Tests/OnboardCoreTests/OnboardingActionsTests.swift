import Foundation
import Testing
@testable import OnboardCore

/// A process runner with exit codes per executable, recording invocations.
private final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var exitCodes: [String: Int32] = [:]
    private var outputs: [String: String] = [:]
    private(set) var calls: [(tool: String, arguments: [String])] = []

    func stub(_ tool: String, exitCode: Int32 = 0, output: String = "") {
        lock.withLock { exitCodes[tool] = exitCode; outputs[tool] = output }
    }

    func run(
        executable: String, arguments: [String], environment: [String: String]?,
        timeout: Duration, lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        lock.withLock {
            let tool = (executable as NSString).lastPathComponent
            calls.append((tool, arguments))
            return ProcessResult(
                exitCode: exitCodes[tool] ?? 0,
                standardOutput: outputs[tool] ?? "",
                standardError: "",
                timedOut: false
            )
        }
    }
}

private struct FakeRoot: OnboardingRootServicing {
    var wallpaperResult: Result<String, Error> = .success("/tmp/w.jpg")
    var demoteResult: Result<Bool, Error> = .success(true)
    func fetchWallpaper(itemID: String, sourceIndex: Int) async throws -> String { try wallpaperResult.get() }
    func demoteConsoleUser(itemID: String) async throws -> Bool { try demoteResult.get() }
}

@Suite struct OnboardingActionRunnerTests {
    private let runner = ScriptedRunner()

    private func makeContext(
        existing: Set<String> = [],
        apps: [String: String] = [:],
        root: FakeRoot = FakeRoot(),
        dock: [String] = []
    ) -> OnboardingActionContext {
        OnboardingActionContext(
            runner: runner,
            desktopprPath: "/H/desktoppr", dockutilPath: "/H/dockutil", utilutiPath: "/H/utiluti",
            rootService: root,
            fileExists: { existing.contains($0) },
            applicationPath: { apps[$0] },
            openTarget: { _ in true },
            currentDockItems: { dock },
            sleep: { _ in }
        )
    }

    @Test func dockSkipsMissingAddsPresentAndRestartsOnce() async {
        let context = makeContext(
            existing: ["/Applications/Edge.app"],
            apps: ["com.microsoft.CompanyPortalMac": "/Applications/Company Portal.app"]
        )
        let item = OnboardingItem(id: "dock", kind: .dock(.init(
            strategies: [.add, .replace],
            items: ["/Applications/Edge.app", "/Applications/Nope.app", "bundleid:com.microsoft.CompanyPortalMac"]
        )))
        let record = await OnboardingActionRunner(context: context).perform(item, choice: .dock(.replace))

        #expect(record.outcome == .success)
        #expect(record.detail == ["added": 2, "skipped": 1])
        let dockutil = runner.calls.filter { $0.tool == "dockutil" }
        #expect(dockutil.first?.arguments == ["--remove", "all", "--no-restart"])
        #expect(dockutil.dropFirst().allSatisfy { $0.arguments.first == "--add" && $0.arguments.contains("--no-restart") })
        #expect(runner.calls.filter { $0.tool == "killall" }.count == 1, "one Dock restart, after all edits")
    }

    /// An app already in the Dock is not added again and does not fail the step.
    @Test func dockCountsAnAlreadyPresentAppAsAddedWithoutCallingDockutil() async {
        let context = makeContext(
            existing: ["/System/Applications/Apps.app", "/Applications/Edge.app"],
            dock: ["/System/Applications/Apps.app"]
        )
        let item = OnboardingItem(id: "dock", kind: .dock(.init(
            strategies: [.add],
            items: ["/System/Applications/Apps.app", "/Applications/Edge.app"]
        )))
        let record = await OnboardingActionRunner(context: context).perform(item, choice: .dock(.add))

        #expect(record.outcome == .success)
        #expect(record.detail == ["added": 2, "skipped": 0])
        let added = runner.calls.filter { $0.tool == "dockutil" && $0.arguments.first == "--add" }
        #expect(added.count == 1, "only the app that was missing is added")
        #expect(added.first?.arguments.contains("/Applications/Edge.app") == true)
    }

    /// Other dockutil failures fail the step, naming the app.
    @Test func dockNamesTheAppItCouldNotAdd() async {
        runner.stub("dockutil", exitCode: 1)
        let context = makeContext(existing: ["/Applications/Edge.app"])
        let item = OnboardingItem(id: "dock", kind: .dock(.init(strategies: [.add], items: ["/Applications/Edge.app"])))
        let record = await OnboardingActionRunner(context: context).perform(item, choice: .dock(.add))

        #expect(record.outcome == .failed)
        #expect(record.message == "could not add /Applications/Edge.app")
    }

    @Test func dockKeepIsASkipThatTouchesNothing() async {
        let item = OnboardingItem(id: "dock", kind: .dock(.init(strategies: [.keep, .add], items: ["/x"])))
        let record = await OnboardingActionRunner(context: makeContext()).perform(item, choice: .dock(.keep))
        #expect(record.outcome == .skipped)
        #expect(runner.calls.isEmpty)
    }

    @Test func absentLocalWallpaperIsASkipNotAFailure() async {
        let item = OnboardingItem(id: "w", kind: .wallpaper(.init(sources: [.path("/Library/Desktop Pictures/corp.jpg")])))
        let record = await OnboardingActionRunner(context: makeContext()).perform(item, choice: nil)
        #expect(record.outcome == .skipped)
    }

    @Test func remoteWallpaperFetchesThroughRootThenApplies() async {
        let source = OnboardingItem.Source.remote(URL(string: "https://x.example/w.jpg")!)
        let item = OnboardingItem(id: "w", kind: .wallpaper(.init(sources: [source])))
        let record = await OnboardingActionRunner(context: makeContext()).perform(item, choice: nil)
        #expect(record.outcome == .success)
        #expect(runner.calls.first?.tool == "desktoppr")
        #expect(runner.calls.first?.arguments == [WallpaperLocation.destination(for: source).path])
    }

    @Test func failedDownloadIsARealFailure() async {
        struct Boom: Error {}
        var root = FakeRoot(); root.wallpaperResult = .failure(Boom())
        let item = OnboardingItem(id: "w", kind: .wallpaper(.init(sources: [.remote(URL(string: "https://x.example/w.jpg")!)])))
        let record = await OnboardingActionRunner(context: makeContext(root: root)).perform(item, choice: nil)
        #expect(record.outcome == .failed)
        #expect(record.status == .downloadFailed)
    }

    /// The utiluti arguments: `url set <scheme> <id>` and `type set <uti> <id>`.
    @Test func defaultAppsUsesUtilutisRealSubcommands() async {
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            urlSchemes: ["mailto": ["com.microsoft.Outlook"]],
            types: ["com.adobe.pdf": ["com.microsoft.edgemac"]]
        )))
        let context = makeContext(apps: [
            "com.microsoft.edgemac": "/Applications/Microsoft Edge.app",
            "com.microsoft.Outlook": "/Applications/Microsoft Outlook.app",
        ])
        let record = await OnboardingActionRunner(context: context).perform(item, choice: nil)
        #expect(record.outcome == .success)

        let calls = runner.calls.filter { $0.tool == "utiluti" }.map(\.arguments)
        #expect(calls.contains(["url", "set", "http", "com.microsoft.edgemac"]))
        #expect(calls.contains(["url", "set", "mailto", "com.microsoft.Outlook"]))
        #expect(calls.contains(["type", "set", "com.adobe.pdf", "com.microsoft.edgemac"]))
        #expect(calls.count == 3)
    }

    /// Targets with no installed candidates are skipped.
    @Test func defaultAppsSkipsWhenNoCandidateIsInstalled() async {
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            urlSchemes: ["mailto": ["com.microsoft.Outlook"]]
        )))
        let record = await OnboardingActionRunner(context: makeContext()).perform(item, choice: nil)
        #expect(record.outcome == .skipped)
        #expect(record.status == .notNeeded)
        #expect(runner.calls.isEmpty, "utiluti must not run for absent apps")
    }

    /// Installed targets are set; missing ones are skipped.
    @Test func defaultAppsActsOnInstalledTargetsAndSkipsAbsentOnes() async {
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(
            browsers: ["com.microsoft.edgemac"],
            urlSchemes: ["mailto": ["com.notinstalled.mail"]]
        )))
        let context = makeContext(apps: ["com.microsoft.edgemac": "/Applications/Microsoft Edge.app"])
        let record = await OnboardingActionRunner(context: context).perform(item, choice: nil)
        #expect(record.outcome == .success)
        let calls = runner.calls.filter { $0.tool == "utiluti" }.map(\.arguments)
        #expect(calls == [["url", "set", "http", "com.microsoft.edgemac"]])
    }

    @Test func defaultAppsRefusalIsRetryableAndNamesTheTarget() async {
        runner.stub("utiluti", exitCode: 1)
        let item = OnboardingItem(id: "d", kind: .defaultApps(.init(browsers: ["com.microsoft.edgemac"])))
        let context = makeContext(apps: ["com.microsoft.edgemac": "/Applications/Microsoft Edge.app"])
        let record = await OnboardingActionRunner(context: context).perform(item, choice: nil)
        #expect(record.outcome == .failed)
        #expect(record.status == .awaitingUser)
        #expect(record.message?.contains("http") == true)
    }

    @Test func demoteMapsRootRepliesToOutcomes() async {
        let item = OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))
        var root = FakeRoot()

        root.demoteResult = .success(true)
        var record = await OnboardingActionRunner(context: makeContext(root: root)).perform(item, choice: nil)
        #expect(record.outcome == .success)

        root.demoteResult = .success(false)
        record = await OnboardingActionRunner(context: makeContext(root: root)).perform(item, choice: nil)
        #expect(record.outcome == .skipped)
    }
}

@Suite struct DockPreviewTests {
    private let current = ["/Apps/Safari.app", "/Apps/Mail.app"]
    private let recommended = ["/Apps/Edge.app", "/Apps/Mail.app", "/Apps/Teams.app"]

    /// `add` appends configured items not already in the Dock.
    @Test func addAppendsWithoutDuplicating() {
        #expect(DockPreview.items(current: current, recommended: recommended, action: .add)
            == ["/Apps/Safari.app", "/Apps/Mail.app", "/Apps/Edge.app", "/Apps/Teams.app"])
    }

    @Test func replaceShowsOnlyTheRecommendation() {
        #expect(DockPreview.items(current: current, recommended: recommended, action: .replace) == recommended)
    }

    @Test func keepShowsTheCurrentDockUntouched() {
        #expect(DockPreview.items(current: current, recommended: recommended, action: .keep) == current)
    }
}

@Suite struct OnboardingRootOperationsTests {
    private let runner = ScriptedRunner()

    private func operations(items: [OnboardingItem], user: String? = "jordy") -> OnboardingRootOperations {
        OnboardingRootOperations(
            loadConfiguration: { Configuration(onboarding: .init(title: nil, message: nil, items: items)) },
            runner: runner,
            consoleUserName: { user },
            download: { _ in throw URLError(.notConnectedToInternet) }
        )
    }

    /// The exclusion list is enforced by the daemon.
    @Test func excludedConsoleUserIsNeverDemoted() async {
        let ops = operations(items: [OnboardingItem(id: "demote", kind: .demoteUser(exclude: ["jordy"]))])
        let reply = await ops.demoteConsoleUser(itemID: "demote")
        #expect(reply.ok)
        #expect(reply.value == "notNeeded")
        #expect(runner.calls.isEmpty, "dseditgroup must not even be consulted")
    }

    /// Membership uses a prefix match: "no reyes is NOT a member" contains "yes".
    @Test func usernameContainingYesIsNotMistakenForMembership() async {
        runner.stub("dseditgroup", output: "no reyes is NOT a member of admin")
        let ops = operations(items: [OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))], user: "reyes")
        let reply = await ops.demoteConsoleUser(itemID: "demote")
        #expect(reply.value == "notNeeded")
        #expect(runner.calls.count == 1, "no edit call may follow a negative answer")
    }

    @Test func nonAdminIsNotNeededAndUnknownItemIsRefused() async {
        runner.stub("dseditgroup", output: "no jordy is NOT a member of admin")
        let ops = operations(items: [OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))])
        #expect(await ops.demoteConsoleUser(itemID: "demote").value == "notNeeded")
        #expect(await ops.demoteConsoleUser(itemID: "other").ok == false)
    }

    @Test func adminIsDemotedViaDseditgroup() async {
        runner.stub("dseditgroup", output: "yes jordy is a member of admin")
        let ops = operations(items: [OnboardingItem(id: "demote", kind: .demoteUser(exclude: []))])
        let reply = await ops.demoteConsoleUser(itemID: "demote")
        #expect(reply.ok)
        #expect(reply.value == "demoted")
        #expect(runner.calls.last?.arguments == ["-o", "edit", "-d", "jordy", "-t", "user", "admin"])
    }

    @Test func wallpaperDownloadFailureComesBackAsTheErrorText() async {
        let ops = operations(items: [OnboardingItem(
            id: "w",
            kind: .wallpaper(.init(sources: [.remote(URL(string: "https://x.example/w.jpg")!)]))
        )])
        let reply = await ops.fetchWallpaper(itemID: "w", sourceIndex: 0)
        #expect(!reply.ok)
        #expect(reply.message?.isEmpty == false)
        #expect(await ops.fetchWallpaper(itemID: "w", sourceIndex: 5).ok == false, "index out of range is refused")
    }
}

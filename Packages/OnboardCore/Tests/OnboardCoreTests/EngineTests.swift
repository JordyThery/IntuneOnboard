import Foundation
import Testing
@testable import OnboardCore

/// Records invocations and plays back scripted results.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let timeout: Duration
    }

    private let lock = NSLock()
    private var results: [ProcessResult]
    private(set) var invocations: [Invocation] = []
    var emitLines: [String] = []

    init(results: [ProcessResult] = [ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)]) {
        self.results = results
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let (result, lines) = lock.withLock {
            invocations.append(Invocation(executable: executable, arguments: arguments, timeout: timeout))
            let result = results.count > 1 ? results.removeFirst() : results[0]
            return (result, emitLines)
        }
        for line in lines {
            lineHandler?(line)
        }
        return result
    }
}

@Suite struct InstallomatorActionTests {
    private func context(runner: FakeProcessRunner, exists: Bool = true) -> ActionContext {
        ActionContext(
            processRunner: runner,
            installomatorPath: "/fake/Installomator.sh",
            installomatorDefaultOptions: ["NOTIFY=silent"],
            fileExists: { _ in exists },
            sleep: { _ in }
        )
    }

    @Test func buildsArgumentsWithDebugZeroLast() async {
        let runner = FakeProcessRunner()
        let item = ProvisioningItem(id: "edge", kind: .installomator(label: "microsoftedge", options: ["INSTALL=force"]))
        let result = await ProvisioningActionRunner.execute(item, context: context(runner: runner))

        #expect(result.outcome == .success)
        let invocation = runner.invocations[0]
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments == [
            "/fake/Installomator.sh", "microsoftedge",
            "NOTIFY=silent", "INSTALL=force", "DEBUG=0",
        ])
        #expect(invocation.timeout == .seconds(1800))
    }

    @Test func missingInstallomatorFails() async {
        let runner = FakeProcessRunner()
        let item = ProvisioningItem(id: "edge", kind: .installomator(label: "microsoftedge", options: []))
        let result = await ProvisioningActionRunner.execute(item, context: context(runner: runner, exists: false))
        #expect(result.outcome == .failed)
        #expect(runner.invocations.isEmpty)
    }

    @Test func nonZeroExitAndTimeoutFail() async {
        var runner = FakeProcessRunner(results: [ProcessResult(exitCode: 3, standardOutput: "", standardError: "", timedOut: false)])
        var item = ProvisioningItem(id: "x", kind: .installomator(label: "l", options: []))
        var result = await ProvisioningActionRunner.execute(item, context: context(runner: runner))
        #expect(result.outcome == .failed)

        runner = FakeProcessRunner(results: [ProcessResult(exitCode: 15, standardOutput: "", standardError: "", timedOut: true)])
        item = ProvisioningItem(id: "y", kind: .installomator(label: "l", options: []))
        result = await ProvisioningActionRunner.execute(item, context: context(runner: runner))
        #expect(result.status == .timedOut)
    }

    @Test func validatePathAppliesAfterSuccess() async {
        let runner = FakeProcessRunner()
        let item = ProvisioningItem(
            id: "m365",
            kind: .installomator(label: "microsoftofficebusinesspro", options: []),
            validatePath: "/Applications/Missing.app"
        )
        // Installomator script "exists", validatePath does not.
        let context = ActionContext(
            processRunner: runner,
            installomatorPath: "/fake/Installomator.sh",
            fileExists: { $0 == "/fake/Installomator.sh" },
            sleep: { _ in }
        )
        let result = await ProvisioningActionRunner.execute(item, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message?.contains("validatePath") == true)
    }
}

@Suite struct ProvisioningEngineTests {
    private func makeStore() -> StateStore {
        StateStore(rootDirectory: FileManager.default.temporaryDirectory
            .appending(path: "engine-tests-\(UUID().uuidString)"))
    }

    private func configuration(items: [ProvisioningItem]) -> Configuration {
        Configuration(provisioning: .init(items: items))
    }

    @Test func successfulRunWritesMarkerAndProgress() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        let runner = FakeProcessRunner()
        let config = configuration(items: [
            ProvisioningItem(id: "a", kind: .installomator(label: "one", options: [])),
            ProvisioningItem(id: "b", kind: .wait(seconds: 1, message: nil)),
        ])
        let context = ActionContext(
            processRunner: runner,
            installomatorPath: "/fake/i.sh",
            fileExists: { _ in true },
            sleep: { _ in }
        )

        let engine = ProvisioningEngine(configuration: config, store: store, context: context)
        let result = await engine.run()

        #expect(result.markerWritten)
        #expect(result.exitCode == .success)
        let state = try #require(try store.loadDeviceState())
        #expect(state.completedAt != nil)
        #expect(state.items["a"]?.outcome == .success)
        #expect(state.items["b"]?.outcome == .success)

        let snapshot = try #require(ProgressSnapshot.read(from: store.progressFileURL))
        #expect(snapshot.engineState == .completed)
        #expect(snapshot.completedCount == 2)
    }

    /// The run's narration has to reach `onboard.log`, which is the only log
    /// the ⌘L panel can read during Setup Assistant. It went to the unified
    /// log alone, so the panel showed the daemon's two startup lines and
    /// nothing about the items at all.
    @Test func everyItemTransitionReachesTheRunLog() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        let collected = StatusCollector()
        let config = configuration(items: [
            ProvisioningItem(id: "a", kind: .wait(seconds: 1, message: nil)),
        ])
        let context = ActionContext(
            processRunner: FakeProcessRunner(),
            logSink: { collected.append($0) },
            fileExists: { _ in true },
            sleep: { _ in }
        )

        _ = await ProvisioningEngine(configuration: config, store: store, context: context).run()

        let lines = collected.lines()
        #expect(lines.contains("item a: starting (attempt 1)"))
        #expect(lines.contains { $0.hasPrefix("item a: success") })
    }

    /// launchd re-spawns the daemon on demand and the card polls every
    /// second, so a failed run restarts within seconds — self-healing when
    /// the fault was transient, an install storm when it is not. After three
    /// attempts the item is left alone, still failed and still blocking the
    /// marker.
    @Test func aFailingItemStopsBeingRetriedAfterThreeAttempts() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "no", timedOut: false),
        ])
        let config = configuration(items: [
            ProvisioningItem(id: "bad", kind: .installomator(label: "nope", options: [])),
        ])
        let context = ActionContext(
            processRunner: runner,
            installomatorPath: "/fake/i.sh",
            fileExists: { _ in true },
            sleep: { _ in }
        )

        // Each pass is one fresh daemon, as launchd would spawn it.
        for _ in 0..<5 {
            _ = await ProvisioningEngine(configuration: config, store: store, context: context).run()
        }

        let state = try #require(try store.loadDeviceState())
        #expect(state.items["bad"]?.outcome == .failed)
        #expect(state.items["bad"]?.attempts == ProvisioningEngine.maxAutomaticAttempts,
                "the fourth and fifth runs must not execute it again")
        #expect(state.completedAt == nil, "a capped failure still withholds the marker")

        // Try again clears the count, so the item runs once more.
        _ = await ProvisioningEngine(
            configuration: config, store: store, context: context, clearAttemptCounts: true
        ).run()
        #expect(try store.loadDeviceState()?.items["bad"]?.attempts == 1)
    }

    /// A `.running` record is a daemon that died mid-item. The failure cap
    /// only ever saw clean failures, so an item that reliably took the daemon
    /// down with it re-ran on every spawn, forever. Out of attempts, the
    /// engine now records the interruption as the failure it was — without
    /// executing the item again — so the run can settle.
    @Test func anItemInterruptedAtTheCapIsRecordedFailedNotReRun() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        var seeded = DeviceState()
        seeded.items["crashy"] = ItemRecord(
            outcome: .running,
            status: .running,
            attempts: ProvisioningEngine.maxAutomaticAttempts
        )
        try store.saveDeviceState(seeded)

        let runner = FakeProcessRunner() // would succeed, if it were ever asked
        let config = configuration(items: [
            ProvisioningItem(id: "crashy", kind: .installomator(label: "l", options: [])),
        ])
        let context = ActionContext(
            processRunner: runner,
            installomatorPath: "/fake/i.sh",
            fileExists: { _ in true },
            sleep: { _ in }
        )
        let result = await ProvisioningEngine(configuration: config, store: store, context: context).run()

        #expect(runner.invocations.isEmpty, "out of attempts — must not execute again")
        let record = try #require(try store.loadDeviceState()?.items["crashy"])
        #expect(record.outcome == .failed)
        #expect(record.attempts == ProvisioningEngine.maxAutomaticAttempts)
        #expect(result.markerWritten == false)
        // The verdict now settles: no further automatic work remains.
        #expect(!ProvisioningEngine.hasAutomaticWorkRemaining(
            items: config.provisioning?.items ?? [],
            records: try #require(try store.loadDeviceState()).items
        ))

        // Below the cap, an interruption is still unfinished work: it re-runs.
        var young = DeviceState()
        young.items["crashy"] = ItemRecord(outcome: .running, status: .running, attempts: 1)
        try store.saveDeviceState(young)
        _ = await ProvisioningEngine(configuration: config, store: store, context: context).run()
        #expect(runner.invocations.count == 1)
        #expect(try store.loadDeviceState()?.items["crashy"]?.outcome == .success)
    }

    /// The item cap stops the item being re-executed; it does not stop the
    /// daemon being re-spawned and running the whole pipeline again. On
    /// hardware that reset the card to "checking this Mac…" every ten
    /// seconds and wiped its buttons, and renamed the Mac each cycle.
    @Test func aSettledRunReportsNoWorkRemaining() {
        let items = [
            ProvisioningItem(id: "ok", kind: .wait(seconds: 1, message: nil)),
            ProvisioningItem(id: "bad", kind: .wait(seconds: 1, message: nil)),
        ]
        let capped = ProvisioningEngine.maxAutomaticAttempts

        #expect(!ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: [
            "ok": ItemRecord(outcome: .success, status: .done, attempts: 1),
            "bad": ItemRecord(outcome: .failed, status: .failed, attempts: capped),
        ]))

        // One attempt left.
        #expect(ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: [
            "ok": ItemRecord(outcome: .success, status: .done, attempts: 1),
            "bad": ItemRecord(outcome: .failed, status: .failed, attempts: capped - 1),
        ]))

        // Never attempted at all.
        #expect(ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: [:]))

        // A daemon that died mid-item left `running` behind: unfinished
        // work, not a verdict.
        #expect(ProvisioningEngine.hasAutomaticWorkRemaining(items: items, records: [
            "ok": ItemRecord(outcome: .running, status: .running, attempts: 1),
            "bad": ItemRecord(outcome: .failed, status: .failed, attempts: capped),
        ]))
    }

    /// A device.json from a build that predates the counter has to keep
    /// decoding: failing would hand the daemon a blank state and re-provision
    /// a Mac that was already finished.
    @Test func aRecordWithoutAnAttemptCountStillDecodes() throws {
        let json = """
        {"outcome":"success","status":"done","detail":{},"updatedAt":"2026-09-19T06:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ItemRecord.self, from: Data(json.utf8))
        #expect(record.outcome == .success)
        #expect(record.attempts == 0)
    }

    @Test func requiredFailureBlocksMarkerOptionalDoesNot() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        // First invocation fails (required item), second succeeds… order matters.
        let runner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "boom", timedOut: false),
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
        ])
        let config = configuration(items: [
            ProvisioningItem(id: "req", kind: .installomator(label: "one", options: [])),
            ProvisioningItem(id: "opt", kind: .installomator(label: "two", options: []), required: false),
        ])
        let context = ActionContext(processRunner: runner, installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })

        let result = await ProvisioningEngine(configuration: config, store: store, context: context).run()
        #expect(!result.markerWritten)
        #expect(result.exitCode == .completedWithErrors)
        #expect(result.failedRequiredIDs == ["req"])

        // Optional failure only: marker must be written.
        let store2 = makeStore()
        defer { try? store2.reset() }
        let runner2 = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false),
        ])
        let context2 = ActionContext(processRunner: runner2, installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })
        let result2 = await ProvisioningEngine(configuration: config, store: store2, context: context2).run()
        #expect(result2.markerWritten)
    }

    @Test func rerunRetriesOnlyFailedAndDisabledIsSkipped() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        let failingRunner = FakeProcessRunner(results: [
            ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
            ProcessResult(exitCode: 1, standardOutput: "", standardError: "", timedOut: false),
        ])
        let config = configuration(items: [
            ProvisioningItem(id: "ok", kind: .installomator(label: "one", options: [])),
            ProvisioningItem(id: "flaky", kind: .installomator(label: "two", options: [])),
            ProvisioningItem(id: "off", kind: .installomator(label: "three", options: []), enabled: false),
        ])
        let context1 = ActionContext(processRunner: failingRunner, installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })
        _ = await ProvisioningEngine(configuration: config, store: store, context: context1).run()
        #expect(failingRunner.invocations.count == 2) // "off" never ran

        var state = try #require(try store.loadDeviceState())
        #expect(state.items["off"]?.outcome == .skipped)
        #expect(state.items["flaky"]?.outcome == .failed)

        // Second pass: only the failed item runs again.
        let retryRunner = FakeProcessRunner()
        let context2 = ActionContext(processRunner: retryRunner, installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })
        let result = await ProvisioningEngine(configuration: config, store: store, context: context2).run()

        #expect(retryRunner.invocations.count == 1)
        #expect(retryRunner.invocations[0].arguments.contains("two"))
        #expect(result.markerWritten)
        state = try #require(try store.loadDeviceState())
        #expect(state.completedAt != nil)
    }

    /// The profile's DEBUG key: nothing executes, nothing persists, the
    /// marker is withheld — but the run renders as a clean success.
    @Test func dryRunExecutesNothingAndPersistsNothing() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        let runner = FakeProcessRunner()
        let config = Configuration(dryRun: true, provisioning: .init(items: [
            ProvisioningItem(id: "a", kind: .installomator(label: "one", options: [])),
            ProvisioningItem(id: "b", kind: .script(.init(source: .inline("exit 1"), interpreter: "/bin/zsh"))),
        ]))
        let context = ActionContext(processRunner: runner, installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })

        let result = await ProvisioningEngine(configuration: config, store: store, context: context).run()

        // Simulated, not executed: even the failing script never ran.
        #expect(runner.invocations.isEmpty)
        #expect(!result.markerWritten)
        #expect(result.dryRun)
        #expect(result.exitCode == .success)

        // Nothing on disk that outlives the run: no device state, no marker.
        #expect(try store.loadDeviceState() == nil)

        // But the UI got a complete, successful run to render.
        let snapshot = try #require(ProgressSnapshot.read(from: store.progressFileURL))
        #expect(snapshot.engineState == .completed)
        #expect(snapshot.completedCount == 2)
        #expect(snapshot.items.allSatisfy { $0.outcome == .success })
    }

    /// A dry run on a Mac with real partial state must neither reuse nor
    /// disturb it: every item simulates, and the state file stays as it was.
    @Test func dryRunLeavesExistingRealStateUntouched() async throws {
        let store = makeStore()
        defer { try? store.reset() }
        var real = DeviceState()
        real.items["a"] = ItemRecord(outcome: .failed, status: .failed)
        try store.saveDeviceState(real)

        let config = Configuration(dryRun: true, provisioning: .init(items: [
            ProvisioningItem(id: "a", kind: .installomator(label: "one", options: [])),
        ]))
        let context = ActionContext(processRunner: FakeProcessRunner(), installomatorPath: "/fake/i.sh", fileExists: { _ in true }, sleep: { _ in })
        let result = await ProvisioningEngine(configuration: config, store: store, context: context).run()

        #expect(result.dryRun)
        let after = try #require(try store.loadDeviceState())
        #expect(after.items["a"]?.outcome == .failed)
        #expect(after.completedAt == nil)
    }
}

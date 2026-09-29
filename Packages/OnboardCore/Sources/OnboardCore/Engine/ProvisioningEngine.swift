import Foundation

/// Runs the provisioning stage: executes its items in order, persists state after
/// every transition, mirrors progress for the UI, and writes the device
/// completion marker per MarkerLogic.
public actor ProvisioningEngine {
    public struct Result: Sendable, Equatable {
        public let markerWritten: Bool
        public let failedRequiredIDs: [String]
        /// True for a `DEBUG` dry run: nothing executed, nothing persisted.
        public let dryRun: Bool
        /// 0 when the marker was written, 30 otherwise. A dry run exits 0 —
        /// nothing really failed; the withheld marker is its normal outcome.
        public var exitCode: ExitCode {
            markerWritten || dryRun ? .success : .completedWithErrors
        }

        public init(markerWritten: Bool, failedRequiredIDs: [String], dryRun: Bool = false) {
            self.markerWritten = markerWritten
            self.failedRequiredIDs = failedRequiredIDs
            self.dryRun = dryRun
        }
    }

    private let configuration: Configuration
    private let store: StateStore
    private let context: ActionContext
    private let onProgress: (@Sendable (ProgressSnapshot) -> Void)?

    private var state: DeviceState
    private var statusTexts: [String: String] = [:]
    private var currentItemID: String?

    /// How many times a failed item is re-executed without being asked.
    ///
    /// launchd re-spawns the daemon on demand (MachServices) and the card
    /// polls every second, so a failed run is picked up again within seconds
    /// — which is how a Mac heals itself during Setup Assistant when the
    /// fault was transient. Unbounded, the same mechanism re-downloads and
    /// re-installs every 15 seconds or so for a fault that is not going to
    /// clear. Three attempts keeps the recovery and drops the storm; the
    /// Retry button clears the count, because a person asking for it has
    /// usually just fixed something.
    public static let maxAutomaticAttempts = 3

    /// Whether another run could still change anything by itself.
    ///
    /// False once every item is terminal and each failed one is out of
    /// attempts. The daemon asks before doing anything, because launchd
    /// re-spawns it every few seconds for as long as a card is polling: with
    /// nothing left to attempt, each spawn still renamed the Mac, re-ran
    /// preflight and republished "checking this Mac…", which wiped the Try
    /// again and Continue anyway buttons off the card about once every ten
    /// seconds. The item cap alone did not stop that — it only stopped the
    /// item being re-executed.
    public static func hasAutomaticWorkRemaining(
        items: [ProvisioningItem],
        records: [String: ItemRecord]
    ) -> Bool {
        for item in items {
            guard item.enabled else { continue }
            guard let record = records[item.id] else { return true }
            switch record.outcome {
            case .success, .skipped:
                continue
            case .failed:
                if record.attempts < maxAutomaticAttempts { return true }
            case .pending, .running:
                // `running` means a previous daemon died mid-item; that is
                // unfinished work, not a verdict.
                return true
            }
        }
        return false
    }

    public init(
        configuration: Configuration,
        store: StateStore = StateStore(),
        context: ActionContext = ActionContext(),
        clearAttemptCounts: Bool = false,
        onProgress: (@Sendable (ProgressSnapshot) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.store = store
        self.context = context
        self.onProgress = onProgress
        // A dry run starts blank on purpose: leftover records from a real
        // partial run would make items skip, and the point of DEBUG is to
        // watch every item go by.
        var loaded = configuration.dryRun
            ? DeviceState()
            : (try? store.loadDeviceState() ?? nil) ?? DeviceState()
        if clearAttemptCounts {
            for id in loaded.items.keys {
                loaded.items[id]?.attempts = 0
            }
        }
        self.state = loaded
    }

    /// Idempotent: already-terminal success/skipped items are never redone;
    /// failed and unfinished items are retried (§4 marker semantics).
    public func run() async -> Result {
        let items = configuration.provisioning?.items ?? []
        state.lastRunAt = .now
        persist(engineState: .running)

        // Wire the shared status-text handler to the item currently running.
        var itemContext = context
        itemContext.statusTextHandler = { [weak self] text in
            Task { await self?.recordStatusText(text) }
        }

        for item in items {
            let previous = state.items[item.id]
            if let existing = previous?.outcome, existing == .success || existing == .skipped {
                continue
            }
            guard item.enabled else {
                setRecord(for: item.id, ItemRecord(outcome: .skipped, status: .notNeeded))
                continue
            }
            // Out of automatic attempts: leave the failure standing, exactly
            // as recorded, so the card still reports it and the marker stays
            // withheld. Only an explicit retry starts it over.
            if let previous, previous.outcome == .failed, previous.attempts >= Self.maxAutomaticAttempts {
                log("item \(item.id): failed \(previous.attempts) times, not retrying automatically — use Try again")
                continue
            }

            let attempts = (previous?.attempts ?? 0) + 1
            currentItemID = item.id
            setRecord(for: item.id, ItemRecord(
                outcome: .running,
                status: runningStatus(for: item.kind),
                attempts: attempts
            ))
            log("item \(item.id): starting (attempt \(attempts))")

            let result: ActionResult
            if configuration.dryRun {
                // DEBUG dry run: pace like work is happening, execute nothing.
                await itemContext.sleep(.seconds(2))
                result = ActionResult(outcome: .success, status: .done, message: "DEBUG — not executed")
            } else {
                result = await ProvisioningActionRunner.execute(item, context: itemContext)
            }

            setRecord(for: item.id, ItemRecord(
                outcome: result.outcome,
                status: result.status,
                message: result.message,
                attempts: attempts
            ))
            currentItemID = nil
            log("item \(item.id): \(result.outcome.rawValue)\(result.message.map { " — " + $0 } ?? "")")
        }

        let requiredIDs = items.filter(\.required).map(\.id)
        let markerEligible = MarkerLogic.markerEligible(requiredIDs: requiredIDs, records: state.items)
        // The device marker is the one thing a dry run must never produce:
        // it is what makes provisioning "done" forever.
        if markerEligible, state.completedAt == nil, !configuration.dryRun {
            state.completedAt = .now
        }
        persist(engineState: markerEligible ? .completed : .completedWithErrors)

        let failed = requiredIDs.filter { state.items[$0]?.outcome == .failed }
        return Result(
            markerWritten: markerEligible && !configuration.dryRun,
            failedRequiredIDs: failed,
            dryRun: configuration.dryRun
        )
    }

    public func currentSnapshot() -> ProgressSnapshot {
        snapshot(engineState: state.completedAt != nil ? .completed : .running)
    }

    // MARK: - Internals

    /// Both destinations, always: the unified log for `log stream`, and the
    /// context's sink for `onboard.log` — the one the ⌘L panel can read
    /// during Setup Assistant.
    private func log(_ message: String) {
        OnboardLog.daemon.notice("\(message, privacy: .public)")
        context.logSink?(message)
    }

    private func recordStatusText(_ text: String) {
        guard let currentItemID else { return }
        statusTexts[currentItemID] = text
        publish(engineState: .running)
    }

    private func runningStatus(for kind: ProvisioningItem.Kind) -> StatusKind {
        switch kind {
        case .installomator: .installing
        case .script: .running
        case .wait, .awaitPath: .waiting
        }
    }

    private func setRecord(for id: String, _ record: ItemRecord) {
        state.items[id] = record
        persist(engineState: .running)
    }

    private func persist(engineState: ProgressSnapshot.EngineState) {
        // A dry run keeps its records in memory only: nothing on disk may
        // outlive it. Progress still publishes (below) — that is rendering,
        // not state.
        if !configuration.dryRun {
            do {
                try store.saveDeviceState(state)
            } catch {
                OnboardLog.daemon.error("state save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        publish(engineState: engineState)
    }

    private func publish(engineState: ProgressSnapshot.EngineState) {
        let snapshot = snapshot(engineState: engineState)
        snapshot.write(to: store.progressFileURL)
        onProgress?(snapshot)
    }

    private func snapshot(engineState: ProgressSnapshot.EngineState) -> ProgressSnapshot {
        let items = (configuration.provisioning?.items ?? []).map { item in
            let record = state.items[item.id]
            return ProgressSnapshot.Item(
                id: item.id,
                outcome: record?.outcome ?? .pending,
                status: record?.status ?? .waiting,
                detail: record?.detail ?? [:],
                statusText: statusTexts[item.id]
            )
        }
        return ProgressSnapshot(
            engineState: engineState,
            items: items,
            startedAt: state.lastRunAt
        )
    }
}

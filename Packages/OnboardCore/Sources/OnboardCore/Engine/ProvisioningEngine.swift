import Foundation

/// Runs provisioning items in order, saves state after every change,
/// publishes progress, and writes the completion marker.
public actor ProvisioningEngine {
    public struct Result: Sendable, Equatable {
        public let markerWritten: Bool
        public let failedRequiredIDs: [String]
        /// A dry run: nothing executed or saved.
        public let dryRun: Bool
        /// 0 when the marker was written or for a dry run; 30 otherwise.
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

    /// Automatic attempts per failed item. The daemon is restarted within
    /// seconds while a window polls it, which retries transient failures;
    /// the limit stops persistent ones from repeating. Try again resets it.
    public static let maxAutomaticAttempts = 3

    /// Whether a new run could change anything without Try again: false
    /// once every enabled item has succeeded, been skipped, or failed the
    /// maximum number of times.
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
                // The previous daemon exited during the item.
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
        // A dry run starts empty so every item is shown.
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

    /// Skips items that succeeded or were skipped; runs the rest.
    public func run() async -> Result {
        let items = configuration.provisioning?.items ?? []
        state.lastRunAt = .now
        persist(engineState: .running)

        // Route `status:` lines to the running item.
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
            // Attempts exhausted: keep the failure until Try again.
            if let previous, previous.outcome == .failed, previous.attempts >= Self.maxAutomaticAttempts {
                log("item \(item.id): failed \(previous.attempts) times, not retrying automatically — use Try again")
                continue
            }
            // Interrupted (the daemon exited mid-item) as many times as the
            // limit allows: record it as failed.
            if let previous, previous.outcome == .running, previous.attempts >= Self.maxAutomaticAttempts {
                log("item \(item.id): interrupted \(previous.attempts) times, not retrying automatically — use Try again")
                setRecord(for: item.id, ItemRecord(
                    outcome: .failed,
                    status: .failed,
                    message: "interrupted mid-run \(previous.attempts) times",
                    attempts: previous.attempts
                ))
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
                // Dry run: wait briefly, execute nothing.
                await itemContext.sleep(.seconds(2))
                result = ActionResult(outcome: .success, status: .done, message: "dry run — not executed")
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
        // Never written by a dry run.
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

    /// Logs to the unified log and to `onboard.log`.
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
        // A dry run saves nothing; progress is still published.
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

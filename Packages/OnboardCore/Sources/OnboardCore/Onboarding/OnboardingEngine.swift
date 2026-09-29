import Foundation

/// A step with its status and last record, as shown in the UI.
public struct StepState: Equatable, Sendable, Identifiable {
    public let item: OnboardingItem
    public let status: StepStatus
    public let record: ItemRecord?

    public var id: String { item.id }

    public init(item: OnboardingItem, status: StepStatus, record: ItemRecord?) {
        self.item = item
        self.status = status
        self.record = record
    }
}

/// Performs one step. Abstracted so the engine is testable.
public protocol OnboardingActing: Sendable {
    func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord
}

/// Runs onboarding for the signed-in user, in the app process: evaluates each
/// step, performs steps on request, saves records and writes the completion
/// marker.
public actor OnboardingEngine {
    private let items: [OnboardingItem]
    private let store: StateStore
    private let probes: OnboardingProbes
    private let actions: OnboardingActing

    private var state: UserState

    public init(
        items: [OnboardingItem],
        store: StateStore = .forCurrentUser(),
        probes: OnboardingProbes,
        actions: OnboardingActing
    ) {
        self.items = items
        self.store = store
        self.probes = probes
        self.actions = actions
        self.state = (try? store.loadUserState() ?? nil) ?? UserState()
    }

    /// Re-evaluates every step. Called at launch and after each step.
    public func refresh() async -> [StepState] {
        var states: [StepState] = []
        for item in items {
            var record = state.items[item.id]
            let status = await OnboardingDerivation.status(
                of: item,
                record: record,
                probes: probes
            )

            // A step already in its desired state is recorded as skipped,
            // since the marker is based on records.
            if status == .completed, record?.outcome.isTerminal != true {
                record = ItemRecord(outcome: .skipped, status: .notNeeded)
                state.items[item.id] = record
                persist()
            }

            states.append(StepState(item: item, status: status, record: record))
        }
        writeMarkerIfEarned(states)
        return states
    }

    /// Performs one step and returns all steps re-evaluated.
    public func perform(itemID: String, choice: StepChoice? = nil) async -> [StepState] {
        guard let item = items.first(where: { $0.id == itemID }), item.enabled else {
            return await refresh()
        }

        state.items[itemID] = ItemRecord(outcome: .running, status: runningStatus(for: item.kind))
        persist()
        OnboardLog.app.notice("onboarding \(itemID, privacy: .public): starting")

        let record = await actions.perform(item, choice: choice)
        state.items[itemID] = record
        persist()
        OnboardLog.app.notice("""
        onboarding \(itemID, privacy: .public): \(record.outcome.rawValue, privacy: .public)\
        \(record.message.map { " — " + $0 } ?? "", privacy: .public)
        """)

        return await refresh()
    }

    /// The current Dock, for the preview.
    public func currentDockItems() async -> [String] {
        await probes.currentDockItems()
    }

    /// Marks a `manual` `open` step as done.
    public func markDone(itemID: String) async -> [StepState] {
        guard let item = items.first(where: { $0.id == itemID }),
              case .open(_, .manual) = item.kind
        else {
            return await refresh()
        }
        state.items[itemID] = ItemRecord(outcome: .success, status: .done)
        persist()
        return await refresh()
    }

    // MARK: - Marker

    /// Written once every required step has succeeded or been skipped.
    private func writeMarkerIfEarned(_ states: [StepState]) {
        guard state.completedAt == nil else { return }
        let requiredIDs = items.filter(\.required).map(\.id)
        guard MarkerLogic.markerEligible(requiredIDs: requiredIDs, records: state.items) else {
            return
        }
        state.completedAt = .now
        persist()
        OnboardLog.app.notice("onboarding: user completion marker written")
    }

    private func runningStatus(for kind: OnboardingItem.Kind) -> StatusKind {
        switch kind {
        case .wallpaper: .downloading
        case .message, .dock, .defaultApps, .demoteUser: .running
        case .open: .awaitingUser
        }
    }

    /// Updates only the fields this engine owns, preserving other changes
    /// made to the file during the session (such as a provisioning dismissal).
    private func persist() {
        do {
            var onDisk = (try? store.loadUserState() ?? nil) ?? UserState()
            onDisk.schemaVersion = state.schemaVersion
            onDisk.items = state.items
            onDisk.completedAt = state.completedAt
            onDisk.appliedWallpaperSHA256 = state.appliedWallpaperSHA256
            try store.saveUserState(onDisk)
        } catch {
            OnboardLog.app.error("user state save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

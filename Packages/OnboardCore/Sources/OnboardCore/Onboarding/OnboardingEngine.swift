import Foundation

/// One step as the UI consumes it: the configured item, its derived standing,
/// and whatever record the last attempt left.
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

/// Executes one step. The concrete router over the five kinds lives with the
/// actions; the engine only needs the shape, which is also what makes the
/// engine testable without touching the Dock or the admin group.
public protocol OnboardingActing: Sendable {
    func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord
}

/// Runs onboarding for the signed-in user: derives every step's standing from
/// the system rather than trusting stored state, executes steps on request, persists
/// per-user records, and writes the user's completion marker.
///
/// Unlike provisioning this runs *in the app*, as the user — there is no XPC
/// between the UI and this engine. Only the two root operations (wallpaper
/// download, demotion) leave the process, inside their actions.
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

    /// Re-derives every step from the system. Called on launch and after
    /// every step, so a setting the user changed behind our back is reflected
    /// the next time the list is looked at.
    public func refresh() async -> [StepState] {
        var states: [StepState] = []
        for item in items {
            var record = state.items[item.id]
            let status = await OnboardingDerivation.status(
                of: item,
                record: record,
                probes: probes
            )

            // A step that is complete without ever having run — the browser
            // was already Edge, the user was never an admin — gets a record
            // saying so, because the completion marker is judged on records
            // and "already in the desired state" is the definition of skipped.
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

    /// Executes one step (the automatic kinds on selection, the interactive
    /// ones from their button) and returns the whole list re-derived.
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

    /// The user's current Dock, for the dock step's live preview.
    public func currentDockItems() async -> [String] {
        await probes.currentDockItems()
    }

    /// Manual completion for `open` steps — the user saying "done". Only that
    /// kind takes their word for it; everything else is derived or measured.
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

    /// The user's completion marker: written once, when every required step's
    /// record is success/skipped. Because `refresh()` records derived
    /// completion and derivation re-checks outcomes (demotion = actually out
    /// of the admin group), marker eligibility *is* outcome validation.
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

    /// Read-modify-write, not a blind overwrite.
    ///
    /// This engine loads the user's state once and holds it for the whole
    /// session, so writing the struct back wholesale discards anything
    /// another part of the app recorded meanwhile. That is exactly how the
    /// provisioning dismissal vanished on hardware: the app wrote it when
    /// the user pressed Continue anyway, and the first completed onboarding
    /// step wrote the pre-dismissal copy straight back over it. Only the
    /// fields this engine owns are carried across.
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

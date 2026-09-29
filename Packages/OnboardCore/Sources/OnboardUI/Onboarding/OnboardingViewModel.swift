import Foundation
import OnboardCore
import Observation

/// Drives the onboarding cards: owns the engine, keeps the derived step
/// list fresh, and models the progression — every step a card, one active,
/// and a single Continue that advances once the active step is satisfied.
@MainActor
@Observable
public final class OnboardingViewModel {
    public private(set) var steps: [StepState] = []
    public private(set) var selectedID: String?
    /// True while an action runs, so the detail pane shows progress and the
    /// buttons don't double-fire.
    public private(set) var isWorking = false

    /// Branding for the sidebar header.
    public let title: String
    public let message: String?
    public let accentHex: String?
    /// The organization's logo — the same artwork as the provisioning header —
    /// shown above the title; nil falls back to the app icon.
    public let headerLogo: IconSpec?
    /// Opened when the user presses Done (the only post-run hook).
    public let launchOnCompletion: OnboardingItem.OpenTarget?
    /// The profile's DEBUG key: everything simulated, badge shown, and Done
    /// opens nothing.
    public let isDryRun: Bool

    private let engine: OnboardingEngine
    private var refreshTask: Task<Void, Never>?

    public init(
        engine: OnboardingEngine,
        title: LocalizedText? = nil,
        message: LocalizedText? = nil,
        accentHex: String? = nil,
        headerLogo: IconSpec? = nil,
        launchOnCompletion: OnboardingItem.OpenTarget? = nil,
        isDryRun: Bool = false
    ) {
        self.engine = engine
        self.title = title?.resolved() ?? OnboardingStrings.defaultTitle
        self.message = message?.resolved() ?? OnboardingStrings.defaultMessage
        self.accentHex = accentHex
        self.headerLogo = headerLogo
        self.launchOnCompletion = launchOnCompletion
        self.isDryRun = isDryRun
    }

    // MARK: - Derived collections

    public var selected: StepState? {
        steps.first { $0.id == selectedID }
    }

    /// The sidebar's queue: still to do, in config order.
    public var suggested: [StepState] {
        steps.filter { $0.status != .completed }
    }

    /// Done, out of the queue but still visible in place — a completed
    /// card collapses rather than disappears.
    public var completed: [StepState] {
        steps.filter { $0.status == .completed }
    }

    /// Continue is enabled when the selected step is satisfied (or was
    /// deliberately left: skipped counts). A failed step does not block — the
    /// user can move on and come back, exactly because the queue keeps it.
    public var canContinue: Bool {
        guard let selected else { return false }
        return selected.status == .completed || selected.status == .canContinue
    }

    public var allDone: Bool {
        !steps.isEmpty && suggested.isEmpty
    }


    // MARK: - Lifecycle

    /// Initial derivation, then a slow re-derivation loop: validatePath steps
    /// complete when another process creates the file, and a setting changed
    /// behind our back should be reflected without relaunching.
    public func start(pollInterval: Duration = .seconds(3)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Intents

    /// Runs the selected step. `choice` carries the user's pick for
    /// array-shaped steps; `nil` confirms a scalar one.
    public func perform(choice: StepChoice? = nil) async {
        guard let selectedID, !isWorking else { return }
        isWorking = true
        steps = await engine.perform(itemID: selectedID, choice: choice)
        isWorking = false
    }

    /// The user's current Dock, for the dock step's live preview.
    public func currentDockItems() async -> [String] {
        await engine.currentDockItems()
    }

    /// Manual completion for `open` steps.
    public func markDone() async {
        guard let selectedID, !isWorking else { return }
        steps = await engine.markDone(itemID: selectedID)
    }

    /// The user pressed Continue: move to the next thing worth doing. Stays
    /// put when the queue is empty — the footer switches to Done.
    public func advance() {
        guard let next = suggested.first(where: { $0.id != selectedID }) ?? suggested.first else {
            return
        }
        selectedID = next.id
    }

    public func select(_ id: String) {
        selectedID = id
    }

    private func refresh() async {
        // Not while an action runs: a re-derivation mid-action would flap the
        // selected step's UI between states.
        guard !isWorking else { return }
        steps = await engine.refresh()
        // Selection moves only by the user's hand (select) or by Continue
        // (advance) — a background refresh never yanks it, however often
        // `start()` gets called. Only an empty or vanished selection is
        // (re)seated, on the first thing worth doing.
        let selectionIsValid = selectedID.map { id in steps.contains { $0.id == id } } ?? false
        if !selectionIsValid {
            selectedID = suggested.first?.id ?? steps.first?.id
        }
    }
}

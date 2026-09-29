import Foundation
import OnboardCore
import Observation

/// Drives the onboarding view: one step is active, and Continue advances once
/// it is satisfied.
@MainActor
@Observable
public final class OnboardingViewModel {
    public private(set) var steps: [StepState] = []
    public private(set) var selectedID: String?
    /// True while an action runs.
    public private(set) var isWorking = false

    /// Branding.
    public let title: String
    public let message: String?
    public let accentHex: String?
    /// Shown above the title; nil shows the app icon.
    public let headerLogo: IconSpec?
    /// Opened when the user presses Done.
    public let launchOnCompletion: OnboardingItem.OpenTarget?
    /// `dryRun`: actions are simulated and Done opens nothing.
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

    /// Steps still to do, in configuration order.
    public var suggested: [StepState] {
        steps.filter { $0.status != .completed }
    }

    /// Completed steps, shown collapsed.
    public var completed: [StepState] {
        steps.filter { $0.status == .completed }
    }

    /// Continue is enabled when the step is done or skipped. A failed step
    /// can be returned to later.
    public var canContinue: Bool {
        guard let selected else { return false }
        return selected.status == .completed || selected.status == .canContinue
    }

    public var allDone: Bool {
        !steps.isEmpty && suggested.isEmpty
    }


    // MARK: - Lifecycle

    /// Evaluates the steps, then re-evaluates periodically so external
    /// changes (such as a validatePath file appearing) are picked up.
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

    /// Performs the selected step. `choice` is the user's selection, or nil
    /// to confirm a single value.
    public func perform(choice: StepChoice? = nil) async {
        guard let selectedID, !isWorking else { return }
        isWorking = true
        steps = await engine.perform(itemID: selectedID, choice: choice)
        isWorking = false
    }

    /// The current Dock, for the preview.
    public func currentDockItems() async -> [String] {
        await engine.currentDockItems()
    }

    /// Marks a `manual` `open` step as done.
    public func markDone() async {
        guard let selectedID, !isWorking else { return }
        steps = await engine.markDone(itemID: selectedID)
    }

    /// Moves to the next step to do. When none remain, the footer shows Done.
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
        // Not while an action runs.
        guard !isWorking else { return }
        steps = await engine.refresh()
        // Selection changes only when the user selects or continues; a
        // refresh only fills an empty or removed selection.
        let selectionIsValid = selectedID.map { id in steps.contains { $0.id == id } } ?? false
        if !selectionIsValid {
            selectedID = suggested.first?.id ?? steps.first?.id
        }
    }
}

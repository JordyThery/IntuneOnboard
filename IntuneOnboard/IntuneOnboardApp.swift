import AppKit
import SwiftUI
import OnboardCore
import OnboardUI
import os

@main
struct IntuneOnboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let arguments = LaunchArguments.current

    private var minimumWindowSize: CGSize {
        RootView.presentationStyle(for: arguments.mode).minimumSize
    }

    /// `onboarding.allowQuit: false` removes the Quit command in user mode.
    private var quitLockedByProfile: Bool {
        guard case .user = arguments.mode else { return false }
        return (try? ConfigLoader.load())?.onboarding?.allowQuit == false
    }

    var body: some Scene {
        // The id is versioned so that previously persisted window state is
        // not restored.
        Window("Intune Onboard", id: "main-2") {
            RootView(arguments: arguments)
                // Small minimum, so the kiosk window can match Setup
                // Assistant's panel at any size.
                .frame(
                    minWidth: minimumWindowSize.width,
                    minHeight: minimumWindowSize.height
                )
                .onAppear { WindowPresenter.presentOnce(for: arguments) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Removes ⌘Q; AppDelegate also refuses termination.
            if arguments.mode.isKiosk || quitLockedByProfile {
                CommandGroup(replacing: .appTermination) {}
            }
        }
    }
}

/// Chooses the view for the launch mode and owns its view models.
struct RootView: View {
    private let arguments: LaunchArguments
    /// `dryRun`: nothing is persisted, including acknowledgements.
    private var isDryRun = false
    /// `onboarding.hideOtherApps`; not applied during a dry run.
    private var hideOtherAppsAtLaunch = false
    /// `onboarding.allowQuit: false`.
    private var quitLocked = false
    /// `onboarding.windowPosition: focus` and its backdrop settings.
    private var focusMode = false
    private var focusBackground: IconSpec?
    private var focusBlur = false
    @State private var model: ProvisioningViewModel
    /// Set in user mode when the profile configures onboarding.
    @State private var onboardingModel: OnboardingViewModel?
    /// Shows a failed or running provisioning run before onboarding; the
    /// provisioning view is where Try again lives.
    @State private var showsProvisioningFirst = false
    /// `requireADE` excludes this Mac: no onboarding, and no way to dismiss.
    private var isIneligible = false

    init(arguments: LaunchArguments) {
        self.arguments = arguments
        _model = State(initialValue: Self.makeModel(for: arguments.mode))
        if arguments.mode == .demo(.onboarding) {
            _onboardingModel = State(initialValue: OnboardingViewModel(
                engine: DemoOnboarding.makeEngine(),
                accentHex: "#0F6CBD",
                headerLogo: .symbol("building.2")
            ))
            focusMode = arguments.forcesFocusMode
            focusBlur = arguments.forcesFocusBlur
        }
        if case .user = arguments.mode {
            let configuration = try? ConfigLoader.load()
            isDryRun = configuration?.dryRun ?? false
            let viewModel = configuration.flatMap { LiveOnboarding.makeViewModel(configuration: $0) }
            _onboardingModel = State(initialValue: viewModel)
            // Decided from disk before the first frame, so the view does not
            // switch after appearing. An unseen failure is always shown first;
            // a run in progress only when no onboarding steps remain.
            let news = ProvisioningState.news(configuration: configuration)
            let outstanding = LiveOnboarding.hasOutstandingWork(configuration: configuration)
            isIneligible = news == .ineligible
            OnboardLog.app.notice(
                "provisioning news: \(String(describing: news), privacy: .public); onboarding outstanding: \(outstanding, privacy: .public)"
            )
            _showsProvisioningFirst = State(
                initialValue: news == .ineligible
                    || news == .unseenFailure
                    || (news == .inProgress && !outstanding)
            )
            // Window behaviour applies only when onboarding is shown.
            if let onboarding = configuration?.onboarding, viewModel != nil {
                hideOtherAppsAtLaunch = onboarding.hideOtherApps && !isDryRun
                quitLocked = !onboarding.allowQuit
                focusMode = onboarding.windowPosition == .focus
                focusBackground = onboarding.background
                focusBlur = onboarding.blur
            }
        }
    }

    var body: some View {
        content
            .onAppear {
                QuitHatch.install(
                    quit: { [model] in
                        await model.prepareForForcedExit()
                    },
                    barcodeOnSpace: arguments.mode.isKiosk || arguments.mode == .demo(.provisioning)
                )

                if arguments.showsLogAtLaunch, case .demo = arguments.mode {
                    // Deferred: opening a window during the first update
                    // conflicts with SwiftUI's own presentation.
                    DispatchQueue.main.async {
                        LogWindow.shared.toggle(over: WindowPresenter.cardWindow)
                    }
                }

                if showsProvisioningFirst {
                    DispatchQueue.main.async { setCardClosable(false) }
                } else {
                    engageOnboardingWindowPolicy()
                }
            }
            .onChange(of: showsProvisioningFirst) { _, showing in
                guard !showing else { return }
                setCardClosable(true)
                engageOnboardingWindowPolicy()
            }
            .onChange(of: model.display.phase) { _, phase in
                exitIfFinished(phase: phase)
            }
            .onChange(of: onboardingModel?.allDone ?? false) { _, _ in
                applyWindowPolicy()
            }
            // The wallpaper step changes the backdrop's default image.
            .onChange(of: onboardingModel?.isWorking ?? false) { _, working in
                if !working { FocusHold.refreshBackdropBackground() }
            }
    }

    /// Removes the close button while provisioning is shown before onboarding.
    /// Closing would leave the app with no window and no Dock icon.
    @MainActor
    private func setCardClosable(_ closable: Bool) {
        guard let window = WindowPresenter.cardWindow else { return }
        if closable {
            window.styleMask.insert(.closable)
        } else {
            window.styleMask.remove(.closable)
        }
    }

    /// Applies `allowQuit`, `windowPosition` and `hideOtherApps`. Not used
    /// while provisioning is shown before onboarding.
    @MainActor
    private func engageOnboardingWindowPolicy() {
        guard quitLocked || hideOtherAppsAtLaunch || focusMode else { return }
        // Deferred until WindowPresenter has configured the window.
        DispatchQueue.main.async {
            applyWindowPolicy()
            if hideOtherAppsAtLaunch {
                NSApp.hideOtherApplications(nil)
            }
        }
    }

    /// Applies `allowQuit` and `windowPosition`; both are lifted once every
    /// step is done.
    @MainActor
    private func applyWindowPolicy() {
        guard quitLocked || focusMode, let window = WindowPresenter.cardWindow else { return }
        let finished = onboardingModel?.allDone ?? false

        if quitLocked {
            if finished {
                window.styleMask.insert(.closable)
                window.styleMask.insert(.miniaturizable)
            } else {
                // Minimize too: the app has no Dock icon to restore from.
                window.styleMask.remove(.closable)
                window.styleMask.remove(.miniaturizable)
            }
        }

        if focusMode {
            // Full screen would move the window to its own Space, away from
            // the backdrop.
            if finished {
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            } else {
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.standardWindowButton(.zoomButton)?.isEnabled = false
            }
        }

        if finished {
            FocusHold.release()
        } else {
            FocusHold.engage(backdrop: focusMode ? (focusBackground, focusBlur) : nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch arguments.mode {
        case .demo(.onboarding):
            // The model is created in init so it survives body re-evaluation.
            if let onboarding = onboardingModel {
                OnboardingView(model: onboarding) {
                    AppTermination.requestExit(reason: "onboarding demo dismissed")
                }
            }
        case .user where onboardingModel != nil && !showsProvisioningFirst:
            let onboarding = onboardingModel!
            OnboardingView(model: onboarding) {
                Task { @MainActor in
                    // A dry run opens nothing.
                    if let target = onboarding.launchOnCompletion, !onboarding.isDryRun {
                        _ = await LiveOnboarding.open(target)
                    }
                    AppTermination.requestExit(reason: "onboarding finished by the user")
                }
            }
        case .setupAssistant, .user, .demo(.provisioning):
            ProvisioningView(
                model: model,
                presentation: presentationStyle,
                onDismiss: dismissAction,
                alwaysAllowsDismiss: showsProvisioningFirst && onboardingModel != nil && !isIneligible
            )
        }
    }

    private var presentationStyle: ProvisioningView.Presentation {
        Self.presentationStyle(for: arguments.mode)
    }

    /// The provisioning demo uses the kiosk layout. Static because the scene
    /// needs it before any view exists.
    static func presentationStyle(for mode: LaunchMode) -> ProvisioningView.Presentation {
        switch mode {
        case .setupAssistant, .demo(.provisioning): .kiosk
        case .user, .demo(.onboarding): .window
        }
    }

    /// No dismiss action in kiosk mode.
    private var dismissAction: (() -> Void)? {
        guard !arguments.mode.isKiosk else { return nil }
        return {
            // Before onboarding, dismissing continues to onboarding instead of
            // quitting — except on an ineligible Mac.
            if showsProvisioningFirst, onboardingModel != nil, !isIneligible {
                rememberDismissedProvisioningRun()
                showsProvisioningFirst = false
                return
            }
            acknowledgeForThisUser()
            AppTermination.requestExit(reason: "dismissed by the user")
        }
    }

    private func rememberDismissedProvisioningRun() {
        guard case .user = arguments.mode, !isDryRun else { return }
        ProvisioningState.rememberDismissal()
    }

    /// Records that the user has seen the completed run, so the next login
    /// shows nothing. Only without onboarding: this sets `UserState.completedAt`,
    /// which is onboarding's completion marker.
    private func acknowledgeForThisUser() {
        guard case .user = arguments.mode, onboardingModel == nil,
              model.display.phase == .completed, !isDryRun
        else { return }

        let store = StateStore.forCurrentUser()
        var state = (try? store.loadUserState()) ?? UserState()
        guard state.completedAt == nil else { return }
        state.completedAt = .now
        do {
            try store.saveUserState(state)
            OnboardLog.app.notice("recorded this user's acknowledgement of the finished run")
        } catch {
            OnboardLog.app.error("could not record acknowledgement: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exitIfFinished(phase: ProvisioningDisplay.Phase) {
        guard arguments.mode.isKiosk else { return }
        // A failed run stays visible unless `allowContinueOnError` is set.
        let shouldExit = phase == .completed
            || (phase == .completedWithErrors && model.display.allowContinueOnError)
        guard shouldExit else { return }

        Task {
            try? await Task.sleep(for: .seconds(5))
            AppTermination.requestExit(reason: "provisioning \(phase.rawValue)")
        }
    }

    @MainActor
    private static func makeModel(for mode: LaunchMode) -> ProvisioningViewModel {
        switch mode {
        case .demo:
            ProvisioningViewModel(
                source: DemoProgressSource(),
                loadConfiguration: { DemoScenario.configuration() }
            )
        case .setupAssistant, .user:
            ProvisioningViewModel(source: OnboardServiceClient())
        }
    }
}

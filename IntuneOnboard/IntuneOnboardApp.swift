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

    /// `onboarding.allowQuit: false` — the user session's version of the
    /// kiosk's missing Quit command. AppDelegate refuses termination as the
    /// backstop; ⌃⌥⌘Q (via AppTermination) stays the administrator's way out.
    private var quitLockedByProfile: Bool {
        guard case .user = arguments.mode else { return false }
        return (try? ConfigLoader.load())?.onboarding?.allowQuit == false
    }

    var body: some Scene {
        // id bumped from "main": SwiftUI persists per-scene state (window
        // frame, split-view column width) keyed by this id, and stored state
        // beats every form of navigationSplitViewColumnWidth — the Air kept a
        // ~137pt sidebar from its first launch through three fix attempts,
        // and this Mac kept 236 the same way. A new id is a clean slate on
        // every Mac; isRestorable=false in WindowPresenter stops new drift.
        Window("Intune Onboard", id: "main-2") {
            RootView(arguments: arguments)
                // The kiosk's minimum is deliberately small: its window has to
                // be able to shrink to Setup Assistant's panel, whatever size
                // that turns out to be on unmeasured hardware.
                .frame(
                    minWidth: minimumWindowSize.width,
                    minHeight: minimumWindowSize.height
                )
                .onAppear { WindowPresenter.presentOnce(for: arguments) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // ⌘Q dismissed the window over Setup Assistant on the first
            // hardware run. Dropping the Quit command takes its key equivalent
            // with it; AppDelegate refuses termination as the real backstop.
            if arguments.mode.isKiosk || quitLockedByProfile {
                CommandGroup(replacing: .appTermination) {}
            }
        }
    }
}

/// Chooses the UI for the launch mode and owns its view model.
struct RootView: View {
    private let arguments: LaunchArguments
    /// The profile's DEBUG key (user mode only): a dry run must not leave the
    /// acknowledgement behind, or the next login would skip the summary the
    /// admin is trying to review.
    private var isDryRun = false
    /// `onboarding.hideOtherApps` — hide everything else when the onboarding
    /// launches. Suppressed under dryRun: a dry run must not rearrange the
    /// user's session.
    private var hideOtherAppsAtLaunch = false
    /// `onboarding.allowQuit: false` — no ⌘Q, no close, no minimize, and the
    /// window stays above other apps until every step is done.
    private var quitLocked = false
    /// `onboarding.windowPosition: focus` plus its backdrop appearance.
    private var focusMode = false
    private var focusBackground: IconSpec?
    private var focusBlur = false
    @State private var model: ProvisioningViewModel
    /// Onboarding, when this is a user session and the profile configures a
    /// onboarding. nil falls back to the provisioning summary (retry/ready screen).
    @State private var onboardingModel: OnboardingViewModel?
    /// A failed provisioning run goes in front of onboarding at login, then
    /// hands over. Retry lives on that card and nowhere else, so without this
    /// a Mac with any onboarding configured could never be retried by the
    /// person sitting at it.
    @State private var showsProvisioningFirst = false
    /// `requireADE` refused this Mac. Onboarding must not run at all, and
    /// the card offers no way past — nothing the person at the keyboard can
    /// do makes the Mac eligible.
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
            // --focus [blur]: review the backdrop without a profile.
            focusMode = arguments.forcesFocusMode
            focusBlur = arguments.forcesFocusBlur
        }
        if case .user = arguments.mode {
            let configuration = try? ConfigLoader.load()
            isDryRun = configuration?.dryRun ?? false
            let viewModel = configuration.flatMap { LiveOnboarding.makeViewModel(configuration: $0) }
            _onboardingModel = State(initialValue: viewModel)
            // Read from disk rather than waiting for the model's first XPC
            // answer: the decision has to be made before the first frame, or
            // onboarding appears and is yanked away a second later.
            //
            // A failure this user has not seen always goes in front. A run
            // still in flight goes in front only when onboarding has nothing
            // left to do — otherwise the steps win, which is what user space
            // is for. Without that second case, a `reset --device` (which
            // takes progress.json with it) showed a *finished* onboarding
            // while provisioning was starting over behind it.
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
            // Only when the onboarding actually shows — the provisioning summary
            // is not a takeover and stays an ordinary window.
            if let onboarding = configuration?.onboarding, viewModel != nil {
                hideOtherAppsAtLaunch = onboarding.hideOtherApps && !isDryRun
                quitLocked = !onboarding.allowQuit
                // A dry run renders the backdrop like everything else — it
                // changes nothing on the Mac, and an admin reviewing the
                // profile should see what their users will get.
                focusMode = onboarding.windowPosition == .focus
                focusBackground = onboarding.background
                focusBlur = onboarding.blur
            }
        }
    }

    var body: some View {
        content
            .onAppear {
                // ⌃⌥⌘Q. Installed in every mode: harmless where ⌘Q already
                // works, essential where it doesn't.
                QuitHatch.install(
                    quit: { [model] in
                        await model.prepareForForcedExit()
                    },
                    barcodeOnSpace: arguments.mode.isKiosk || arguments.mode == .demo(.provisioning)
                )

                if arguments.showsLogAtLaunch, case .demo = arguments.mode {
                    // Next runloop turn: opening a window from inside the
                    // first view update races SwiftUI's own presentation.
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
            // The failure card handed over: only now does the takeover start.
            .onChange(of: showsProvisioningFirst) { _, showing in
                guard !showing else { return }
                setCardClosable(true)
                engageOnboardingWindowPolicy()
            }
            .onChange(of: model.display.phase) { _, phase in
                exitIfFinished(phase: phase)
            }
            // The lock and the backdrop are both "is there work left?"
            // questions, so they follow the onboarding's state rather than
            // being set once at launch.
            .onChange(of: onboardingModel?.allDone ?? false) { _, _ in
                applyWindowPolicy()
            }
            // A step just finished: the wallpaper one changes the desktop
            // picture the backdrop defaults to, so it has to catch up.
            // (Lifting for another app is handled by FocusBackdrop itself,
            // which watches app activation.)
            .onChange(of: onboardingModel?.isWorking ?? false) { _, working in
                if !working { FocusHold.refreshBackdropBackground() }
            }
    }

    /// The traffic light is not an exit while the failure card stands in
    /// front of onboarding. Closing it left an `LSUIElement` app with no
    /// window, no Dock icon and no way back to the steps the person still
    /// had to do — a dead end a hardware run walked straight into. The
    /// card's own button is the way through, and it is always offered here.
    @MainActor
    private func setCardClosable(_ closable: Bool) {
        guard let window = WindowPresenter.cardWindow else { return }
        if closable {
            window.styleMask.insert(.closable)
        } else {
            window.styleMask.remove(.closable)
        }
    }

    /// The onboarding takeover — quit lock, focus backdrop, hide-others.
    /// Deliberately not applied while the provisioning failure card is up: a
    /// locked window over a card whose only button is "Try again" is a trap,
    /// and that summary was never meant to be a takeover.
    @MainActor
    private func engageOnboardingWindowPolicy() {
        guard quitLocked || hideOtherAppsAtLaunch || focusMode else { return }
        // After WindowPresenter has configured the window (a window touched
        // from inside the first view update races SwiftUI's presentation).
        DispatchQueue.main.async {
            applyWindowPolicy()
            if hideOtherAppsAtLaunch {
                // Once, at launch. windowPosition: focus is what actually
                // keeps the screen; this is the opening nudge.
                NSApp.hideOtherApplications(nil)
            }
        }
    }

    /// Applies `allowQuit` and `windowPosition` to the real window. Both
    /// relax once onboarding is finished: the point is to keep someone in
    /// the flow, not to hold a completed window hostage.
    @MainActor
    private func applyWindowPolicy() {
        guard quitLocked || focusMode, let window = WindowPresenter.cardWindow else { return }
        let finished = onboardingModel?.allDone ?? false

        if quitLocked {
            if finished {
                window.styleMask.insert(.closable)
                window.styleMask.insert(.miniaturizable)
            } else {
                // The reference disables the close button; we take the
                // minimize button too, because this app has no Dock icon
                // (LSUIElement) — a minimized window would have nowhere to
                // come back from.
                window.styleMask.remove(.closable)
                window.styleMask.remove(.miniaturizable)
            }
        }

        if focusMode {
            // No full-screening out of a focus run: a full-screen window
            // gets its own Space and would leave the backdrop behind on the
            // old one, which is precisely the gap this mode closes.
            if finished {
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.standardWindowButton(.zoomButton)?.isEnabled = true
            } else {
                window.collectionBehavior.remove(.fullScreenPrimary)
                window.standardWindowButton(.zoomButton)?.isEnabled = false
            }
        }

        // FocusHold owns the card's level and the backdrop together: they
        // have to move as one, or a held card covers the app the onboarding
        // just sent the user to.
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
            // Onboarding against the in-memory demo world: fully interactive,
            // nothing on the real system changes. The model is built in
            // `init` like the user-mode one, so the window policy can observe
            // it — and so a body re-evaluation can't hand the view a brand
            // new engine with the demo's progress wiped.
            if let onboarding = onboardingModel {
                OnboardingView(model: onboarding) {
                    AppTermination.requestExit(reason: "onboarding demo dismissed")
                }
            }
        case .user where onboardingModel != nil && !showsProvisioningFirst:
            // Onboarding: user space is what this stage is for.
            let onboarding = onboardingModel!
            OnboardingView(model: onboarding) {
                Task { @MainActor in
                    // The only post-run hook, by decision: open something,
                    // then get out of the way. A dry run opens nothing —
                    // launching an app is the one visible thing it could do.
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

    /// `--demo provisioning` shows the kiosk composition deliberately: it
    /// exists to review the Setup Assistant experience, and it stays closable
    /// because demo mode isn't a kiosk.
    ///
    /// Static because the scene needs it too, to size the window before any
    /// view exists.
    static func presentationStyle(for mode: LaunchMode) -> ProvisioningView.Presentation {
        switch mode {
        case .setupAssistant, .demo(.provisioning): .kiosk
        case .user, .demo(.onboarding): .window
        }
    }

    /// Kiosk modes have no way out: no button, no ⌘Q. The app leaves on its
    /// own once the run is done, or with the session.
    private var dismissAction: (() -> Void)? {
        guard !arguments.mode.isKiosk else { return nil }
        return {
            // The failure card shown ahead of onboarding hands over instead
            // of quitting — whether it was retried into shape or read and
            // waved past, the user still has their own steps to do.
            // Not on an ineligible Mac: the profile refused it, so there is
            // nothing legitimate to hand over to. Handing over is how a
            // user-enrolled VM ended up with its account demoted by a
            // configuration that had just declined to provision it.
            if showsProvisioningFirst, onboardingModel != nil, !isIneligible {
                rememberDismissedProvisioningRun()
                showsProvisioningFirst = false
                return
            }
            acknowledgeForThisUser()
            AppTermination.requestExit(reason: "dismissed by the user")
        }
    }

    /// Records that this user has seen the failed run, unless this is a dry
    /// run — a rehearsal must not silence the real thing.
    private func rememberDismissedProvisioningRun() {
        guard case .user = arguments.mode, !isDryRun else { return }
        ProvisioningState.rememberDismissal()
    }

    /// Records that this user has seen the finished run, so the next login
    /// doesn't greet them with "Your Mac is ready" all over again —
    /// `UserSessionGate` reads this back. Only a finished run is worth
    /// acknowledging: dismissing mid-run shouldn't silence the UI for good.
    ///
    /// Not when onboarding is configured. The flag it sets is
    /// `UserState.completedAt`, which is *onboarding's* completion marker —
    /// writing it here would tell the app the user had finished steps they
    /// had never been shown. That was harmless while this card only ever
    /// appeared with no onboarding behind it; it no longer only does.
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
            // Worst case the completion screen shows once more next login.
            OnboardLog.app.error("could not record acknowledgement: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func exitIfFinished(phase: ProvisioningDisplay.Phase) {
        guard arguments.mode.isKiosk else { return }
        // A clean finish gets out of the way so Setup Assistant can carry on.
        // A failed run stays up to be read, unless the profile explicitly
        // allows continuing past errors; either way the session teardown
        // takes the window with it.
        let shouldExit = phase == .completed
            || (phase == .completedWithErrors && model.display.allowContinueOnError)
        guard shouldExit else { return }

        Task {
            // Long enough to read the finished state.
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

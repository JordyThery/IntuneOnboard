import AppKit
import OnboardCore
import OnboardUI
import os

/// Sizes and places the card's window: on Setup Assistant's card if it ever
/// has one of its own, otherwise card-sized and centred on its backdrop, so
/// it reads as part of the setup flow rather than an app over it.
///
/// Setting a window frame in AppKit is the whole trick. Positioning the card
/// *inside* a screen-sized window needs the view's offset from the screen,
/// which SwiftUI won't give straight: inferring it from the content height was
/// 39 pt out (a menu bar), and using the window frame was still 3.5 pt out,
/// because oversized content is centred in its container.
@MainActor
private func matchSetupAssistantPanel(_ window: NSWindow) {
    // `NSScreen.screens.first` is the primary display — the one at origin
    // (0,0) with the menu bar, which is where Setup Assistant runs.
    // `NSScreen.main` is the *focused* screen and on a multi-display Mac
    // picked the wrong one.
    guard let screen = NSScreen.screens.first ?? window.screen else { return }
    let target = SetupAssistantPanel.windowFrame(
        matching: SetupAssistantPanel.currentFrame(screen: screen.frame),
        screen: screen.frame
    )
    if window.frame != target {
        window.setFrame(target, display: true)
    }
}

/// Hides and disables the traffic lights, and takes the zoom/full-screen
/// affordance away. `.titled` is required for the window to be able to become
/// key (and so for ⌃⌥⌘Q to work at all), but it brings the buttons with it.
@MainActor
private func stripChrome(_ window: NSWindow) {
    window.styleMask.remove(.resizable)
    window.styleMask.remove(.closable)
    window.styleMask.remove(.miniaturizable)
    window.collectionBehavior.remove(.fullScreenPrimary)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = window.standardWindowButton(kind)
        button?.isHidden = true
        button?.isEnabled = false
    }
}

/// Presents the main window for the current launch mode and logs the session
/// diagnostics: user, uid, window level, geometry and launch method. The app
/// is LSUIElement, so activation is always programmatic.
@MainActor
enum WindowPresenter {
    private static var hasPresented = false
    private static var screenObserver: NSObjectProtocol?

    /// The card's window: the first one that is neither the ⌘L log panel nor
    /// the kiosk blocker. Taking `NSApp.windows.first` outright configured the
    /// panel instead whenever it happened to be created first, leaving the app
    /// running with nothing visible at all.
    static var cardWindow: NSWindow? {
        let ours: Set<NSUserInterfaceItemIdentifier> = [
            LogWindow.identifier,
            KioskBlocker.identifier,
            BarcodeWindow.identifier,
            FocusBackdrop.identifier,
        ]
        return NSApp.windows.first { window in
            window.identifier.map { !ours.contains($0) } ?? true
        }
    }

    /// A display being plugged in, unplugged or changing resolution moves
    /// Setup Assistant's panel — and a run can last long enough for that to
    /// happen, especially on a Mac mini or a Mac being set up on a dock. Left
    /// alone, the card would stay at the old rectangle with the panel visible
    /// beside it, and the blocker would stop covering the screen.
    ///
    /// The notification also fires when the menu bar's height changes, which
    /// is the class of thing that used to break the alignment outright.
    private static func observeScreenChanges(for window: NSWindow) {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                OnboardLog.app.notice("screen parameters changed — re-matching the panel")
                matchSetupAssistantPanel(window)
                KioskBlocker.install(below: window.level)
            }
        }
    }

    /// Presentation runs once per launch. SwiftUI calls `.onAppear` again after
    /// the styleMask/frame changes below, which is what produced the duplicate
    /// log line on the first hardware run.
    static func presentOnce(for arguments: LaunchArguments) {
        guard !hasPresented else { return }
        hasPresented = true
        present(for: arguments)
    }

    private static func present(for arguments: LaunchArguments) {
        guard let window = cardWindow else {
            OnboardLog.app.error("WindowPresenter: no window to present")
            return
        }

        // Every mode: this window's geometry is code-defined (the kiosk
        // matches Setup Assistant, the user window is the 800×600 card), so
        // nothing about it should be restored across launches. Persisted
        // state silently beat our sizing twice — the ballooned first launch,
        // then a stored sidebar width that overrode every column-width fix.
        window.isRestorable = false

        switch arguments.mode {
        case .setupAssistant:
            // Cover the whole screen above Setup Assistant / login window
            // chrome. screenSaver + 1 is what the M0 hardware run validated;
            // --window-level lets a test run try other levels without
            // rebuilding (see Docs/SetupAssistant-Findings.md).
            let level = arguments.windowLevelOverride ?? NSWindow.Level.screenSaver.rawValue + 1
            window.level = NSWindow.Level(rawValue: level)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            // Blocking clicks is now a separate, screen-sized window, which is
            // what frees the card's own window to be nothing but Setup
            // Assistant's panel rectangle.
            KioskBlocker.install(below: window.level)

            // Deliberately NOT .borderless: a borderless NSWindow returns
            // canBecomeKey == false, so it never receives keyDown — which
            // silently disabled the ⌃⌥⌘Q escape hatch in exactly the modes it
            // exists for. Titled + transparent titlebar looks identical and
            // can take key events.
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovable = false

            // Transparent so the rounded corners the card clips itself to are
            // actually round, and shadowed the way a panel on the setup
            // backdrop is. Setup Assistant's blurred wallpaper stays visible
            // around it; its panel does not, because ours is right on top.
            //
            // Both alternatives were tried on hardware and are wrong: a dim
            // scrim left Setup Assistant's panel and its Enroll button
            // readable behind ours (two competing cards), and filling the
            // screen with our own opaque backdrop erased the wallpaper and
            // left the card adrift in a blank expanse.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true

            // SwiftUI reconfigures the window after this runs — it put the
            // traffic lights back (the green one let someone un-maximise out
            // of the kiosk) and it re-sizes the window to fit its content.
            // Apply the geometry and chrome now, and again once SwiftUI has
            // had its turn.
            matchSetupAssistantPanel(window)
            stripChrome(window)
            DispatchQueue.main.async {
                matchSetupAssistantPanel(window)
                stripChrome(window)
            }
            observeScreenChanges(for: window)
        case .user, .demo:
            // Put the window back to normal explicitly. SwiftUI persists a
            // scene's frame, so after a kiosk launch the saved geometry is
            // borderless and screen-sized — a later user-session window
            // inherits it and comes up full screen with no title bar.
            window.level = .normal
            window.collectionBehavior = []
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // The provisioning card's size, so the onboarding and the Setup
            // Assistant screen read as one product (user feedback from the
            // first M4 hardware run).
            window.setContentSize(NSSize(width: 800, height: 600))

            // Centre on the primary display rather than `center()`, which
            // uses whichever screen the window happens to be on — on a
            // multi-display Mac that opened onboarding on a secondary monitor.
            if let screen = NSScreen.screens.first {
                let size = window.frame.size
                window.setFrameOrigin(CGPoint(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2
                ))
            } else {
                window.center()
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // frame caught the kiosk geometry leaking into later launches;
        // canBecomeKey caught the escape hatch being unable to fire. The
        // origin is logged too, now that coinciding with Setup Assistant's
        // panel is the thing most likely to be wrong on unfamiliar hardware.
        let frame = window.frame
        let screenFrame = NSScreen.screens.first?.frame ?? .zero
        let panel = SetupAssistantPanel.currentFrame(screen: screenFrame)
        OnboardLog.app.notice("""
        window: mode=\(arguments.mode.description, privacy: .public) \
        user=\(NSUserName(), privacy: .public) uid=\(getuid()) \
        windowLevel=\(window.level.rawValue) \
        frame=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.minX)),\(Int(frame.minY)) \
        screen=\(screenFrame.debugDescription, privacy: .public) \
        panel=\(panel?.debugDescription ?? "none (centred instead)", privacy: .public) \
        setupAssistantWindows=[\(SetupAssistantPanel.windowCensus(), privacy: .public)] \
        canBecomeKey=\(window.canBecomeKey) isKey=\(window.isKeyWindow) \
        styleMask=\(window.styleMask.rawValue) \
        zoomHidden=\(window.standardWindowButton(.zoomButton)?.isHidden ?? true) \
        launchedBy=\(arguments.launchedBy, privacy: .public)
        """)
    }
}

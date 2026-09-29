import AppKit
import OnboardCore
import OnboardUI
import os

/// Sets the provisioning window's frame from Setup Assistant's panel, or
/// 800×600 centred when there is none.
@MainActor
private func matchSetupAssistantPanel(_ window: NSWindow) {
    // The primary display, where Setup Assistant runs. `NSScreen.main` is the
    // focused screen, which can be another display.
    guard let screen = NSScreen.screens.first ?? window.screen else { return }
    let target = SetupAssistantPanel.windowFrame(
        matching: SetupAssistantPanel.currentFrame(screen: screen.frame),
        screen: screen.frame
    )
    if window.frame != target {
        window.setFrame(target, display: true)
    }
}

/// Hides the window buttons and full-screen control. The window must stay
/// `.titled` to become key and receive ⌃⌥⌘Q.
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

/// Configures and shows the main window for the launch mode, and logs the
/// session details.
@MainActor
enum WindowPresenter {
    private static var hasPresented = false
    private static var screenObserver: NSObjectProtocol?

    /// The main window: the first window that is not one of the auxiliary
    /// windows below.
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

    /// Re-applies geometry and click blocking when displays or the menu bar
    /// change.
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

    /// Runs once; SwiftUI calls `.onAppear` again after the window changes.
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

        // Geometry is set in code; restored state would override it.
        window.isRestorable = false

        switch arguments.mode {
        case .setupAssistant:
            let level = arguments.windowLevelOverride ?? NSWindow.Level.screenSaver.rawValue + 1
            window.level = NSWindow.Level(rawValue: level)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            KioskBlocker.install(below: window.level)

            // Not .borderless: a borderless window cannot become key.
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovable = false

            // Transparent, so the view's rounded corners show Setup
            // Assistant's background.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true

            // SwiftUI reconfigures the window after this runs, so apply again
            // on the next turn of the run loop.
            matchSetupAssistantPanel(window)
            stripChrome(window)
            DispatchQueue.main.async {
                matchSetupAssistantPanel(window)
                stripChrome(window)
            }
            observeScreenChanges(for: window)
        case .user, .demo:
            // Reset explicitly, in case SwiftUI restored kiosk geometry.
            window.level = .normal
            window.collectionBehavior = []
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 800, height: 600))

            // On the primary display; `center()` uses the window's current screen.
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

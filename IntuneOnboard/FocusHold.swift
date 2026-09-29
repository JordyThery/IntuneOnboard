import AppKit
import OnboardCore
import OnboardUI
import os

/// Keeps the onboarding in front while there is work left, and steps aside for
/// the apps onboarding itself sent the user to.
///
/// Two profile keys arrive here. `allowQuit: false` raises the card above
/// ordinary windows so a browser can't bury it; `windowPosition: focus` adds
/// the screen-filling backdrop. Both need the same exception, which is why
/// they share one owner: when an exempt app comes forward the backdrop goes
/// away **and the card drops back to the normal window level** — on hardware
/// the backdrop lifted correctly but the floating card still sat on top of
/// Company Portal, which could then never reach the front.
@MainActor
enum FocusHold {
    /// The level the card is held at while nothing exempt is frontmost.
    private static let heldLevel = NSWindow.Level.floating

    private static var isEngaged = false
    private static var backdrop: (background: IconSpec?, blur: Bool)?
    private static var observers: [NSObjectProtocol] = []
    private static var isSteppedAside = false

    /// - Parameter backdrop: the focus backdrop's appearance, or nil to hold
    ///   the window in front without one (`allowQuit: false` alone).
    static func engage(backdrop: (background: IconSpec?, blur: Bool)?) {
        Self.backdrop = backdrop
        isEngaged = true
        watchActivations()
        apply(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// The run is over: the card becomes an ordinary window again.
    static func release() {
        guard isEngaged else { return }
        isEngaged = false
        backdrop = nil
        isSteppedAside = false
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        FocusBackdrop.tearDown()
        WindowPresenter.cardWindow?.level = .normal
    }

    /// Re-reads the wallpaper the backdrop defaults to; called when a step
    /// finishes, because the onboarding's own wallpaper step changes it.
    static func refreshBackdropBackground() {
        FocusBackdrop.refreshBackground()
    }

    // MARK: - Internals

    private static func watchActivations() {
        guard observers.isEmpty else { return }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Read the bundle id here: NSRunningApplication must not cross
            // into the main-actor hop below.
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated { apply(frontmost: bundleID) }
        })

        // Belt to the workspace notification's braces: this app is
        // LSUIElement and activates programmatically, so its own activation
        // is the case least safe to assume arrives as a workspace event.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply(frontmost: Bundle.main.bundleIdentifier) }
        })

        // A display plugged in, unplugged or re-arranged mid-run: the
        // backdrop has to cover whatever the screens are now. (The kiosk's
        // equivalent lives in WindowPresenter; this one is onboarding's.)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard isEngaged, !isSteppedAside else { return }
                // Torn down first so `apply` rebuilds for the new screens.
                FocusBackdrop.tearDown()
                apply(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        })
    }

    private static func apply(frontmost bundleID: String?) {
        guard isEngaged, let card = WindowPresenter.cardWindow else { return }
        let stepAside = FocusExemptions.allowsBackdropLift(for: bundleID)

        // The level has to move with the backdrop. Held above everything, the
        // card would cover the very app the onboarding asked the user to use.
        card.level = stepAside ? .normal : heldLevel

        if let backdrop {
            if stepAside {
                FocusBackdrop.tearDown()
            } else {
                // Only build when there is nothing up: this runs on every app
                // switch, and rebuilding a screen-sized window each time
                // would flicker for no reason.
                if !FocusBackdrop.isVisible {
                    FocusBackdrop.show(below: heldLevel, background: backdrop.background, blur: backdrop.blur)
                }
                // orderFront, never makeKey: the card belongs above the
                // backdrop, but stealing key focus from whatever the user is
                // typing into would be its own bug.
                card.orderFront(nil)
            }
        }

        guard stepAside != isSteppedAside else { return }
        isSteppedAside = stepAside
        OnboardLog.app.notice("""
        focus hold: \(stepAside ? "stepped aside for" : "back in front of", privacy: .public) \
        \(bundleID ?? "an unknown app", privacy: .public)
        """)
    }
}

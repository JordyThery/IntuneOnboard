import AppKit
import OnboardCore
import OnboardUI
import os

/// Keeps the onboarding window in front while steps remain, and steps aside
/// for apps that onboarding opened.
///
/// Handles `allowQuit: false` (window held at floating level) and
/// `windowPosition: focus` (backdrop). The window level and the backdrop
/// change together; otherwise a floating window would still cover an app the
/// user was sent to.
@MainActor
enum FocusHold {
    private static let heldLevel = NSWindow.Level.floating

    private static var isEngaged = false
    private static var backdrop: (background: IconSpec?, blur: Bool)?
    private static var observers: [NSObjectProtocol] = []
    private static var isSteppedAside = false

    /// - Parameter backdrop: the backdrop's appearance, or nil to hold the
    ///   window in front without one.
    static func engage(backdrop: (background: IconSpec?, blur: Bool)?) {
        Self.backdrop = backdrop
        isEngaged = true
        watchActivations()
        apply(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Returns the window to normal behaviour.
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

    /// Call after a step finishes; the wallpaper step changes the backdrop.
    static func refreshBackdropBackground() {
        guard let backdrop, backdrop.background == nil else { return }
        Task {
            let path = await LiveOnboarding.currentWallpaperPath()
            FocusBackdrop.refreshBackground(wallpaperPath: path)
        }
    }

    // MARK: - Internals

    private static func watchActivations() {
        guard observers.isEmpty else { return }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            // Extract the id before the main-actor hop; NSRunningApplication
            // is not Sendable.
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated { apply(frontmost: bundleID) }
        })

        // This app's own activation, which may not arrive as a workspace event.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply(frontmost: Bundle.main.bundleIdentifier) }
        })

        // Cover displays added or rearranged while engaged.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard isEngaged, !isSteppedAside else { return }
                FocusBackdrop.tearDown()
                apply(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            }
        })
    }

    private static func apply(frontmost bundleID: String?) {
        guard isEngaged, let card = WindowPresenter.cardWindow else { return }
        let stepAside = FocusExemptions.allowsBackdropLift(for: bundleID)

        card.level = stepAside ? .normal : heldLevel

        if let backdrop {
            if stepAside {
                FocusBackdrop.tearDown()
            } else {
                // Runs on every app switch; only build when not already shown.
                if !FocusBackdrop.isVisible {
                    FocusBackdrop.show(below: heldLevel, background: backdrop.background, blur: backdrop.blur)
                }
                // Not makeKey: do not take keyboard focus from the active app.
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

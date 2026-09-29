import AppKit
import OnboardCore
import OnboardUI
import SwiftUI
import os

/// `onboarding.windowPosition: focus` — a backdrop filling every screen
/// beneath the onboarding card, so nothing else can be seen or clicked while there
/// is onboarding left to do. The onboarding sibling of `KioskBlocker`, and the
/// answer to what `hideOtherApps` alone can't do: that key hides other apps
/// once, at launch, and cannot stop the user opening one afterwards.
///
/// One window per screen — a second display left uncovered would defeat
/// the point — borderless so it can never take key focus away from the card —
/// which would cost the ⌃⌥⌘Q hatch — and opaque so clicks stop here.
///
/// Purely the windows: whether they should be up right now, and how the
/// card sits relative to them, is `FocusHold`'s job.
@MainActor
enum FocusBackdrop {
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.focusBackdrop")

    private static var windows: [NSWindow] = []
    private static var appearance: (background: IconSpec?, blur: Bool) = (nil, false)

    /// Puts the backdrop up (or moves it, after a display change). `level` is
    /// the card's level; the backdrop goes directly beneath it.
    static func show(below level: NSWindow.Level, background: IconSpec?, blur: Bool) {
        appearance = (background, blur)
        guard !NSScreen.screens.isEmpty else {
            OnboardLog.app.error("focus backdrop: no screen to cover")
            return
        }

        // Rebuild rather than reuse: screens come and go mid-run, and one
        // window per screen is cheap enough to make that the simple case.
        tearDown()
        for screen in NSScreen.screens {
            let window = make(for: screen)
            window.level = NSWindow.Level(rawValue: level.rawValue - 1)
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            windows.append(window)
        }

        OnboardLog.app.notice("""
        focus backdrop: screens=\(windows.count) level=\(windows.first?.level.rawValue ?? 0) \
        blur=\(blur) background=\(background == nil ? "wallpaper" : "configured", privacy: .public)
        """)
    }

    static var isVisible: Bool { !windows.isEmpty }

    /// The wallpaper default has to follow the wallpaper: the onboarding's own
    /// wallpaper step changes it mid-run, and a backdrop still showing the
    /// picture from login makes the step look like it did nothing. Swaps the
    /// content rather than rebuilding the windows, so there is no flash.
    static func refreshBackground() {
        guard !windows.isEmpty, appearance.background == nil else { return }
        for window in windows {
            guard let screen = window.screen ?? NSScreen.screens.first,
                  let host = window.contentView as? NSHostingView<BackdropView>
            else { continue }
            host.rootView = BackdropView(
                image: NSWorkspace.shared.desktopImageURL(for: screen).map { .path($0.path) },
                blur: appearance.blur
            )
        }
    }

    static func tearDown() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static func make(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.identifier = identifier
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isMovable = false
        window.isRestorable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: BackdropView(
            // nil defaults to whatever this screen is already showing, so
            // the backdrop reads as the Mac's own desktop rather than a
            // foreign wall of colour.
            image: appearance.background ?? NSWorkspace.shared.desktopImageURL(for: screen).map { .path($0.path) },
            blur: appearance.blur
        ))
        return window
    }
}

private struct BackdropView: View {
    let image: IconSpec?
    let blur: Bool

    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)
            if let image {
                BackdropImage(spec: image)
                    .blur(radius: blur ? 30 : 0)
                    // Clipped after blurring: a blur samples past the edges
                    // and would otherwise feather into the background.
                    .clipped()
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
    }
}

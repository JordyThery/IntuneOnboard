import AppKit
import OnboardCore
import OnboardUI
import SwiftUI
import os

/// The `windowPosition: focus` backdrop: one opaque, borderless window per
/// screen, directly below the onboarding window. Borderless windows cannot
/// become key, so the onboarding window keeps keyboard focus. `FocusHold`
/// decides when it is shown.
@MainActor
enum FocusBackdrop {
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.focusBackdrop")

    private static var windows: [NSWindow] = []
    private static var appearance: (background: IconSpec?, blur: Bool) = (nil, false)
    /// The wallpaper reported by desktoppr after a step; nil until the first refresh.
    private static var wallpaperPath: String?

    /// Shows the backdrop, or rebuilds it for the current screens.
    static func show(below level: NSWindow.Level, background: IconSpec?, blur: Bool) {
        appearance = (background, blur)
        guard !NSScreen.screens.isEmpty else {
            OnboardLog.app.error("focus backdrop: no screen to cover")
            return
        }

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

    /// Updates a wallpaper-based backdrop after the wallpaper changes,
    /// without recreating the windows.
    static func refreshBackground(wallpaperPath path: String?) {
        if let path { wallpaperPath = path }
        guard !windows.isEmpty, appearance.background == nil else { return }
        for window in windows {
            guard let screen = window.screen ?? NSScreen.screens.first,
                  let host = window.contentView as? NSHostingView<BackdropView>
            else { continue }
            host.rootView = BackdropView(image: wallpaper(for: screen), blur: appearance.blur)
        }
    }

    /// `NSWorkspace` can report the previous wallpaper for a while after
    /// another process changes it, so a path from desktoppr takes precedence.
    private static func wallpaper(for screen: NSScreen) -> IconSpec? {
        if let wallpaperPath { return .path(wallpaperPath) }
        return NSWorkspace.shared.desktopImageURL(for: screen).map { .path($0.path) }
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
            // Defaults to the screen's current wallpaper.
            image: appearance.background ?? wallpaper(for: screen),
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
                    // Clip after blurring so the edges do not fade.
                    .clipped()
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
    }
}

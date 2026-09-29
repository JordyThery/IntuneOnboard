import AppKit
import OnboardCore
import os

/// Invisible windows that intercept clicks around the provisioning window
/// during Setup Assistant.
///
/// Borderless, so they cannot become key and take ⌃⌥⌘Q or ⌘L from the
/// provisioning window.
@MainActor
enum KioskBlocker {
    private static var windows: [NSWindow] = []

    /// One window per screen, directly below `level`. Call again when screens
    /// change.
    static func install(below level: NSWindow.Level) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            OnboardLog.app.error("kiosk blocker: no screen to cover")
            return
        }

        while windows.count < screens.count { windows.append(make()) }
        while windows.count > screens.count { windows.removeLast().orderOut(nil) }

        for (blocker, screen) in zip(windows, screens) {
            blocker.level = NSWindow.Level(rawValue: level.rawValue - 1)
            blocker.setFrame(frame(for: screen), display: true)
            blocker.orderFront(nil)
        }

        OnboardLog.app.notice("""
        kiosk blocker: \(windows.count) screen(s), first frame=\(windows[0].frame.debugDescription, privacy: .public) \
        level=\(windows[0].level.rawValue) canBecomeKey=\(windows[0].canBecomeKey)
        """)
    }

    private static func make() -> NSWindow {
        let blocker = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        blocker.identifier = identifier
        blocker.isOpaque = false
        // Near-transparent rather than clear, so the window is always hit-tested.
        blocker.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        blocker.hasShadow = false
        blocker.ignoresMouseEvents = false
        blocker.isMovable = false
        blocker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return blocker
    }

    /// The screen below the menu bar, which stays usable for Setup
    /// Assistant's accessibility options.
    private static func frame(for screen: NSScreen) -> CGRect {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height - menuBar
        )
    }

    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.kioskBlocker")
}

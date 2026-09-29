import AppKit
import OnboardCore
import os

/// An invisible full-screen window that swallows clicks, so the kiosk's only
/// real guarantee holds: nothing behind the card can be *reached*, even though
/// the card itself is only panel-sized.
///
/// This used to be the card's own window — screen-sized and transparent, with
/// the card positioned somewhere inside it. That made the card's placement a
/// SwiftUI coordinate problem, and every attempt at it was a few points out.
/// Splitting the two jobs means the card's window can simply *be* Setup
/// Assistant's panel rectangle, and blocking stays a separate, dumb concern.
///
/// Borderless on purpose: this window must never take key focus, or it would
/// steal ⌃⌥⌘Q and ⌘L from the card. A borderless window can't become key,
/// which is a liability there and exactly the behaviour wanted here.
@MainActor
enum KioskBlocker {
    private static var window: NSWindow?

    /// `level` is the card's level; the blocker goes directly beneath it.
    static func install(below level: NSWindow.Level) {
        guard let screen = NSScreen.screens.first else {
            OnboardLog.app.error("kiosk blocker: no screen to cover")
            return
        }

        let blocker = window ?? make()
        window = blocker
        blocker.level = NSWindow.Level(rawValue: level.rawValue - 1)
        blocker.setFrame(frame(for: screen), display: true)
        blocker.orderFront(nil)

        OnboardLog.app.notice("""
        kiosk blocker: frame=\(blocker.frame.debugDescription, privacy: .public) \
        level=\(blocker.level.rawValue) canBecomeKey=\(blocker.canBecomeKey)
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
        // Not fully transparent: a window with a clear background still
        // hit-tests, but this is one pixel of insurance against a compositor
        // that decides an entirely invisible window needn't be hit-tested.
        blocker.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        blocker.hasShadow = false
        blocker.ignoresMouseEvents = false
        blocker.isMovable = false
        blocker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return blocker
    }

    /// Everything below the menu bar. The menu bar strip is deliberately left
    /// alone: our window has always sat under it (a `.titled` window is kept
    /// there, and the escape hatch needs `.titled` to receive keys), the first
    /// hardware run was accepted that way, and during Setup Assistant that
    /// strip is where the accessibility options live.
    private static func frame(for screen: NSScreen) -> CGRect {
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height - menuBar
        )
    }

    /// Tagged like the log panel so `WindowPresenter` can tell the card's
    /// window from the others it owns.
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.kioskBlocker")
}

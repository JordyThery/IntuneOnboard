import AppKit
import OnboardCore
import OnboardUI
import os
import SwiftUI

/// The ⌘L log panel as its own window, placed to the left of the card and
/// overlapping it, so the card stays readable while the log is open.
///
/// A real window rather than a sheet so it can be moved, resized and left open
/// beside the card while a run proceeds. In the kiosk it has to sit *above* the
/// full-screen window, or it would open behind it where nobody could reach it.
@MainActor
final class LogWindow {
    static let shared = LogWindow()

    /// Tagged so `WindowPresenter` can tell the card's window from this one.
    /// It used to take `NSApp.windows.first`, which meant whichever window
    /// existed first — and with the panel open at launch that was the panel,
    /// so the card was never presented at all.
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.logPanel")

    private var window: NSWindow?

    /// The height is a starting point only — `frame(besideCardIn:)` matches
    /// the card's. The width has to carry four tabs beside the traffic lights;
    /// at 440 the fourth ("Intune") squeezed "Installomator" into an ellipsis.
    private static let size = CGSize(width: 520, height: 660)
    /// How far the panel's right edge laps over the card's left edge.
    private static let overlap: CGFloat = 40

    func toggle(over host: NSWindow?) {
        if let window, window.isVisible {
            close()
        } else {
            show(over: host)
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    private func show(over host: NSWindow?) {
        let panel = window ?? make()
        window = panel

        panel.setFrame(frame(besideCardIn: host), display: true)
        // Above the kiosk window, which sits at screenSaver + 1.
        panel.level = host.map { NSWindow.Level(rawValue: $0.level.rawValue + 1) } ?? .floating
        panel.makeKeyAndOrderFront(nil)

        OnboardLog.app.notice("log window shown at \(panel.frame.debugDescription, privacy: .public)")
    }

    private func make() -> NSWindow {
        let panel = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.identifier
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LogViewer { [weak self] in
            self?.close()
        })
        // The zoom button would let someone resize this over the whole screen
        // during Setup Assistant; close and drag are enough.
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        return panel
    }

    /// Right edge tucked just inside the card's left edge, top edge level
    /// with it, so the two read as one arrangement. Clamped to the screen so
    /// a narrow display can't push it off.
    ///
    /// Measured off the host window's real frame, not an assumed card width:
    /// the card's window is now Setup Assistant's panel rectangle, whatever
    /// that is on the hardware in hand.
    private func frame(besideCardIn host: NSWindow?) -> CGRect {
        let screen = NSScreen.screens.first ?? host?.screen
        guard let visible = screen?.visibleFrame else {
            return CGRect(origin: .zero, size: Self.size)
        }

        // Fall back to a centred card of the usual size if there is no host to
        // measure, so the panel still lands somewhere sensible.
        let card = host?.frame ?? CGRect(
            x: visible.midX - Self.size.width / 2,
            y: visible.midY - Self.size.height / 2,
            width: Self.size.width,
            height: Self.size.height
        )

        // As tall as the card, within reason: a panel taller than what it sits
        // beside looked like a mistake rather than a pair.
        let height = min(max(card.height, 320), visible.height - 16)
        let x = max(visible.minX + 8, card.minX - Self.size.width + Self.overlap)
        let y = min(max(visible.minY + 8, card.maxY - height), visible.maxY - height)

        return CGRect(x: x, y: y, width: Self.size.width, height: height)
    }
}

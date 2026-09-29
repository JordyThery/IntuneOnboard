import AppKit
import OnboardCore
import OnboardUI
import os
import SwiftUI

/// The ⌘L log panel: a separate window, beside and overlapping the main
/// window, one level above it so it is reachable over Setup Assistant.
@MainActor
final class LogWindow {
    static let shared = LogWindow()

    /// Distinguishes this window from the main window.
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.logPanel")

    private var window: NSWindow?

    /// The height follows the main window; the width fits four tabs.
    private static let size = CGSize(width: 520, height: 660)
    /// Overlap with the main window's left edge.
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
        // No zoom: it would cover the screen during Setup Assistant.
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        return panel
    }

    /// Left of the main window, overlapping it, top-aligned, and clamped to
    /// the screen.
    private func frame(besideCardIn host: NSWindow?) -> CGRect {
        let screen = NSScreen.screens.first ?? host?.screen
        guard let visible = screen?.visibleFrame else {
            return CGRect(origin: .zero, size: Self.size)
        }

        let card = host?.frame ?? CGRect(
            x: visible.midX - Self.size.width / 2,
            y: visible.midY - Self.size.height / 2,
            width: Self.size.width,
            height: Self.size.height
        )

        let height = min(max(card.height, 320), visible.height - 16)
        let x = max(visible.minX + 8, card.minX - Self.size.width + Self.overlap)
        let y = min(max(visible.minY + 8, card.maxY - height), visible.maxY - height)

        return CGRect(x: x, y: y, width: Self.size.width, height: height)
    }
}

import AppKit
import CoreImage.CIFilterBuiltins
import OnboardCore
import SwiftUI

/// Space toggles a window with the serial number as a scannable barcode —
/// bench-provisioning ergonomics: the technician points the asset scanner at
/// the screen instead of flipping the Mac over mid-enrollment.
///
/// Kiosk-only (plus the provisioning demo, for review): in the user-space
/// onboarding, space belongs to the focused control.
@MainActor
final class BarcodeWindow {
    static let shared = BarcodeWindow()

    /// Tagged so `WindowPresenter.cardWindow` never mistakes this for the card.
    static let identifier = NSUserInterfaceItemIdentifier("be.jordythery.intuneonboard.barcode")

    private var window: NSWindow?

    func toggle(over host: NSWindow?) {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show(over: host)
        }
    }

    private func show(over host: NSWindow?) {
        let panel = window ?? make()
        window = panel

        // Centred on the card (or the screen), one level above the kiosk —
        // same placement rules as the log window.
        let size = panel.frame.size
        let anchor = host?.frame
            ?? NSScreen.screens.first.map(\.visibleFrame)
            ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2
        ))
        panel.level = host.map { NSWindow.Level(rawValue: $0.level.rawValue + 1) } ?? .floating
        panel.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let serial = DeviceInfo.current().serialNumber
        let panel = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.identifier
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: BarcodeView(serial: serial))
        return panel
    }
}

private struct BarcodeView: View {
    let serial: String?

    var body: some View {
        VStack(spacing: 12) {
            if let serial, let barcode = Barcode.image(for: serial, width: 380, height: 110) {
                Image(nsImage: barcode)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 380, height: 110)
                Text(serial)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(verbatim: "—")
                    .font(.title)
                Text("The serial number could not be read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 440, height: 220)
        .background(Color(.windowBackgroundColor))
    }
}

/// Code 128, the symbology asset scanners expect for serials. Rendered at
/// integer scale with interpolation off so the bars stay crisp.
private enum Barcode {
    static func image(for text: String, width: CGFloat, height: CGFloat) -> NSImage? {
        guard let data = text.data(using: .ascii) else { return nil }
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = data
        filter.quietSpace = 4
        guard let output = filter.outputImage else { return nil }

        let scale = max(1, (width / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(
            scaleX: scale,
            y: height / output.extent.height
        ))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: scaled.extent.size)
    }
}

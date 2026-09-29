import CoreImage
import CoreImage.CIFilterBuiltins
import OnboardCore
import SwiftUI

/// The help button and its popover. The URL is shown as a QR code, since
/// no browser is available during Setup Assistant.
struct HelpPopover: View {
    let help: Configuration.Help

    var body: some View {
        VStack(spacing: 12) {
            if let title = help.title?.resolved() {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            if let message = help.message?.resolved() {
                // Markdown is rendered.
                Text(LocalizedStringKey(message))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = help.url {
                if let qr = QRCode.image(for: url, side: 168) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(Text(verbatim: url.absoluteString))
                }

                Text(url.host ?? url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}

enum QRCode {
    /// Scaled without smoothing, so the code stays sharp.
    static func image(for url: URL, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}

#Preview("Help") {
    HelpPopover(help: Configuration.Help(
        title: LocalizedText(plain: "Need a hand?"),
        message: LocalizedText(plain: "Scan this to reach the **IT service desk**."),
        url: URL(string: "https://example.com/support")
    ))
}

import AppKit
import OnboardCore
import SwiftUI

/// The focus backdrop's fill image. Any icon source works, so an admin can
/// point `onboarding.background` at an https URL or a file on disk.
///
/// Scaled to fill and clipped: an organization's artwork shouldn't be
/// letterboxed, and the backdrop has to cover the whole screen regardless of
/// the image's aspect ratio.
///
/// Public because the app's focus backdrop is the consumer.
public struct BackdropImage: View {
    let spec: IconSpec

    public init(spec: IconSpec) {
        self.spec = spec
    }

    public var body: some View {
        switch spec {
        case .remote(let url):
            RemoteIcon(url: url, size: .infinity) { Color.clear }
                .scaledToFill()
        case .path(let path):
            fill(NSImage(contentsOfFile: path))
        case .named(let name):
            fill(NSImage(named: name))
        case .symbol, .bundleID:
            // Neither makes sense stretched across a screen; the backdrop
            // keeps the window background colour instead.
            Color.clear
        }
    }

    @ViewBuilder
    private func fill(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color.clear
        }
    }
}

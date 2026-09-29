import AppKit
import OnboardCore
import SwiftUI

/// The `focus` backdrop image, from any icon source, scaled to fill the screen.
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
            // Not used for backdrops; the window background shows instead.
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

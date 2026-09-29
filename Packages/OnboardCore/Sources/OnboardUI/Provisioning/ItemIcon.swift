import AppKit
import OnboardCore
import SwiftUI

/// Renders an `IconSpec`. Unresolvable icons show a placeholder symbol;
/// apps often are not installed yet when provisioning starts.
struct ItemIcon: View {
    let spec: IconSpec?
    var fallbackSymbol = "app.dashed"
    var size: CGFloat = 32
    /// Symbols use the tint by default; set white for use on the accent colour.
    var symbolStyle: AnyShapeStyle?

    var body: some View {
        switch spec {
        case .symbol(let name):
            symbol(name)
        case .named(let name):
            image(NSImage(named: name))
        case .path(let path):
            image(FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path)
                : nil)
        case .bundleID(let identifier):
            image(NSWorkspace.shared.applicationIcon(bundleIdentifier: identifier))
        case .remote(let url):
            RemoteIcon(url: url, size: size) { symbol(fallbackSymbol) }
        case nil:
            symbol(fallbackSymbol)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.72))
            .foregroundStyle(symbolStyle ?? AnyShapeStyle(.tint))
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func image(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            symbol(fallbackSymbol)
        }
    }
}

/// Downloads each icon URL once per process. `AsyncImage` would refetch on
/// every view rebuild, which happens on every progress update.
struct RemoteIcon<Fallback: View>: View {
    let url: URL
    let size: CGFloat
    @ViewBuilder var fallback: Fallback

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                fallback
            } else {
                // Reserve the space while loading.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            if let cached = await RemoteIconCache.shared.image(for: url) {
                image = cached
            } else {
                failed = true
            }
        }
    }
}

/// Process-wide icon cache.
actor RemoteIconCache {
    static let shared = RemoteIconCache()

    private var images: [URL: NSImage] = [:]
    private var known: Set<URL> = []

    func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        guard !known.contains(url) || images[url] != nil else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                OnboardLog.app.notice("icon \(url.lastPathComponent, privacy: .public): HTTP \(http.statusCode)")
                known.insert(url)
                return nil
            }
            guard let image = NSImage(data: data) else {
                OnboardLog.app.notice("icon \(url.lastPathComponent, privacy: .public): not an image")
                known.insert(url)
                return nil
            }
            images[url] = image
            return image
        } catch {
            // Common during Setup Assistant before the network is up.
            OnboardLog.app.notice("""
            icon \(url.lastPathComponent, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
            known.insert(url)
            return nil
        }
    }
}

private extension NSWorkspace {
    /// nil while the app is not yet installed.
    func applicationIcon(bundleIdentifier: String) -> NSImage? {
        guard let url = urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return icon(forFile: url.path)
    }
}

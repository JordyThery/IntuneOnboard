import CoreGraphics
import Foundation

/// Where to place the provisioning window over Setup Assistant.
///
/// Setup Assistant draws its card inside one full-screen window, so there is
/// normally no card window to match; the window is then `fallbackSize`,
/// centred. A smaller Setup Assistant window is matched if one exists.
public enum SetupAssistantPanel {
    /// Used when there is no card window to match.
    public static let fallbackSize = CGSize(width: 800, height: 600)

    /// Accepted spellings of Setup Assistant's process name.
    public static let ownerNames = ["Setup Assistant", "SetupAssistant"]

    /// Windows covering more of the screen than this are the backdrop.
    public static let largestPanelShareOfScreen: CGFloat = 0.6

    /// The card window's frame in CoreGraphics coordinates (origin top-left
    /// of the primary display, y down), or nil if there is none. Reads only
    /// window owner names and bounds, which need no Screen Recording access.
    public static func currentFrame(screen: CGRect) -> CGRect? {
        frame(fromWindowList: currentWindowList(), screen: screen)
    }

    /// The largest Setup Assistant window of card size: above a minimum
    /// size and below the backdrop threshold.
    public static func frame(fromWindowList windows: [[String: Any]], screen: CGRect) -> CGRect? {
        let screenArea = screen.width * screen.height
        let panels = setupAssistantWindows(in: windows).filter { panel in
            guard panel.width >= 400, panel.height >= 300 else { return false }
            guard screenArea > 0 else { return true }
            return (panel.width * panel.height) / screenArea <= largestPanelShareOfScreen
        }
        return panels.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// All Setup Assistant windows.
    public static func setupAssistantWindows(in windows: [[String: Any]]) -> [CGRect] {
        windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(owner),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let width = bounds["Width"],
                  let height = bounds["Height"]
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    /// Setup Assistant's windows, for the log.
    public static func windowCensus() -> String {
        let windows = setupAssistantWindows(in: currentWindowList())
        guard !windows.isEmpty else { return "none" }
        return windows
            .map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" }
            .joined(separator: " ")
    }

    private static func currentWindowList() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// The window frame in AppKit coordinates (origin bottom-left of the
    /// primary display, y up).
    ///
    /// `screen` must be the primary display's frame; both coordinate systems
    /// are anchored to it. Without a panel, `fallbackSize` is centred, which
    /// matches where Setup Assistant places its card.
    public static func windowFrame(matching panel: CGRect?, screen: CGRect) -> CGRect {
        guard let panel else {
            return CGRect(
                x: screen.midX - fallbackSize.width / 2,
                y: screen.midY - fallbackSize.height / 2,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }

        // Flip y: the panel's bottom edge in CoreGraphics is its origin in
        // AppKit. x is the same in both.
        return CGRect(
            x: panel.minX,
            y: screen.maxY - panel.maxY,
            width: panel.width,
            height: panel.height
        )
    }
}

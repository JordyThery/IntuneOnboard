import CoreGraphics
import Foundation

/// Where to put the provisioning card so it reads as part of the setup flow:
/// a card-sized window centred on Setup Assistant's backdrop, matching the
/// panel the system itself draws.
///
/// **Setup Assistant does not put its card in a window of its own.** It draws
/// one full-screen window — the blue backdrop — with the rounded card as a
/// subview. Measured on a 15-inch Air: matching "Setup Assistant's largest
/// window" therefore made our window full screen, which stretched the card
/// edge to edge and hid the backdrop entirely. An earlier version of this file
/// assumed a separate 798×595 panel window and was verified against a
/// stand-in built to that assumption, which is why the mistake survived.
///
/// So a screen-sized window is recognised as the backdrop and deliberately
/// *not* matched. The card gets `fallbackSize`, centred — which is what the
/// reference does too: its window is its own size on Apple's backdrop, not a
/// copy of Apple's card. Anything smaller that Setup Assistant does own is
/// still matched, in case a release puts the card in a real window.
public enum SetupAssistantPanel {
    /// The card's size when there is no panel window to match — which, on
    /// current macOS, is always.
    public static let fallbackSize = CGSize(width: 800, height: 600)

    /// The process is `/System/Library/CoreServices/Setup Assistant.app`;
    /// the spelling has varied, so accept the plausible forms.
    public static let ownerNames = ["Setup Assistant", "SetupAssistant"]

    /// A window covering more of the screen than this is the backdrop, not a
    /// card. Apple's card is roughly a quarter of a laptop screen; the
    /// backdrop is all of it, so there is a lot of room between the two.
    public static let largestPanelShareOfScreen: CGFloat = 0.6

    /// The panel's rectangle in CoreGraphics display coordinates: origin
    /// top-left of the primary display, y growing *down*. `nil` when Setup
    /// Assistant owns nothing card-shaped, including the usual case where all
    /// it owns is the full-screen backdrop.
    ///
    /// Only window metadata — owner name and bounds — which needs no Screen
    /// Recording permission. Window *titles* would.
    public static func currentFrame(screen: CGRect) -> CGRect? {
        frame(fromWindowList: currentWindowList(), screen: screen)
    }

    /// The largest window belonging to Setup Assistant that could be a card:
    /// big enough to be one (it also draws tooltips, shadows and the odd 1×1)
    /// and small enough not to be the backdrop.
    public static func frame(fromWindowList windows: [[String: Any]], screen: CGRect) -> CGRect? {
        let screenArea = screen.width * screen.height
        let panels = setupAssistantWindows(in: windows).filter { panel in
            guard panel.width >= 400, panel.height >= 300 else { return false }
            guard screenArea > 0 else { return true }
            return (panel.width * panel.height) / screenArea <= largestPanelShareOfScreen
        }
        return panels.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Every window Setup Assistant owns, unfiltered.
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

    /// What Setup Assistant actually had on screen, for the log. The
    /// assumption this file got wrong was invisible precisely because nothing
    /// ever recorded it from real hardware.
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

    /// Where to put our window, in AppKit screen coordinates (origin
    /// bottom-left of the primary display, y growing *up*).
    ///
    /// `screen` must be the **primary** display's frame — the one with the menu
    /// bar, at AppKit's origin. Both coordinate systems are anchored to it, so
    /// its height is the only quantity needed to flip between them, and a panel
    /// on a second display converts correctly for free.
    ///
    /// Nothing here is derived from the size of the display or the height of
    /// the menu bar, which is what makes this portable: a 14-inch with a notch
    /// (39 pt menu bar), a non-notched Air (24 pt) and an external monitor all
    /// go through the same arithmetic. The bug this replaced was exactly a
    /// menu-bar assumption.
    ///
    /// With no panel to match — a user session, the demo, or Setup Assistant
    /// not yet on screen — the fallback size is centred, which is where Setup
    /// Assistant puts its panel anyway (measured: a 595 pt panel on an 1169 pt
    /// screen sits 287 pt from the top, dead centre).
    ///
    /// Doing this in AppKit is the whole point: the previous attempt positioned
    /// a card *inside* a screen-sized SwiftUI view, which meant inferring where
    /// that view sat relative to the screen. Every version of that inference
    /// was a few points out — `ignoresSafeArea` makes the content screen-tall
    /// while it stays anchored at the window's top, and oversized content gets
    /// centred in its container. A window frame has no such ambiguity, and can
    /// be verified from outside the process.
    public static func windowFrame(matching panel: CGRect?, screen: CGRect) -> CGRect {
        guard let panel else {
            return CGRect(
                x: screen.midX - fallbackSize.width / 2,
                y: screen.midY - fallbackSize.height / 2,
                width: fallbackSize.width,
                height: fallbackSize.height
            )
        }

        // CoreGraphics measures y down from the top of the primary display,
        // AppKit up from its bottom: the panel's *bottom* edge in CG is its
        // origin in AppKit. x needs no conversion — both grow rightwards from
        // the same edge.
        return CGRect(
            x: panel.minX,
            y: screen.maxY - panel.maxY,
            width: panel.width,
            height: panel.height
        )
    }
}

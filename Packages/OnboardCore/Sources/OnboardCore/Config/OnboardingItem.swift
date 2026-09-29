import Foundation

/// One step of onboarding, the per-user stage.
public struct OnboardingItem: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// Runs on appear with visible state.
        case automatic
        /// The user presses a button.
        case interactive
    }

    public enum Kind: Equatable, Sendable {
        /// Information only — a title and a message, nothing else. No
        /// interaction: looking at it completes it.
        case message
        case wallpaper(WallpaperSpec)
        case dock(DockSpec)
        case defaultApps(DefaultAppsSpec)
        case open(target: OpenTarget, completion: OpenCompletion)
        case demoteUser(exclude: [String])
    }

    public enum Source: Equatable, Sendable {
        case path(String)
        case remote(URL)
    }

    /// Throughout the onboarding config, **scalar means confirm, array means
    /// choose**: one value renders a confirmation the user acknowledges,
    /// several render a picker. One rule instead of a per-step flag — a
    /// single value can only be accepted, several have to be chosen from.
    public struct WallpaperSpec: Equatable, Sendable {
        /// One source = applied/confirmed; several = the user picks from a
        /// grid.
        public let sources: [Source]
        /// Verified after download. Only allowed with exactly one source —
        /// one hash cannot vouch for several files (validator-enforced).
        public let sha256: String?
        /// Offer "keep the current wallpaper" as an outcome.
        public let allowKeepExisting: Bool

        public init(sources: [Source], sha256: String? = nil, allowKeepExisting: Bool = false) {
            self.sources = sources
            self.sha256 = sha256
            self.allowKeepExisting = allowKeepExisting
        }
    }

    public enum DockStrategy: String, Sendable, CaseIterable {
        /// Leave the Dock alone.
        case keep
        /// Append the configured items to the current Dock.
        case add
        /// Remove everything, then add the configured items.
        case replace
    }

    public struct DockSpec: Equatable, Sendable {
        /// One strategy = performed as configured; several = the user
        /// chooses. "Keep current" is expressed by including `keep`, so
        /// there is no separate allowKeepExisting here.
        public let strategies: [DockStrategy]
        /// Paths or `bundleid:` entries; missing apps are skipped and reported
        /// as "X added, Y skipped".
        public let items: [String]
        /// Wait for apps still being installed by provisioning.
        public let waitForItemsTimeout: Int
        public let restartDock: Bool

        public init(strategies: [DockStrategy] = [.add], items: [String], waitForItemsTimeout: Int = 0, restartDock: Bool = true) {
            self.strategies = strategies
            self.items = items
            self.waitForItemsTimeout = waitForItemsTimeout
            self.restartDock = restartDock
        }
    }

    public struct DefaultAppsSpec: Equatable, Sendable {
        /// Bundle ids, set via the `http` scheme. One = confirm, several =
        /// the user picks from side-by-side candidates.
        public let browsers: [String]
        /// scheme → candidate bundle ids (e.g. mailto).
        public let urlSchemes: [String: [String]]
        /// UTI → candidate bundle ids.
        public let types: [String: [String]]
        /// Offer "keep the current default" as an outcome.
        public let allowKeepExisting: Bool
        /// Shown before triggering, because macOS asks the user to confirm.
        public let explanation: LocalizedText?

        public init(
            browsers: [String] = [],
            urlSchemes: [String: [String]] = [:],
            types: [String: [String]] = [:],
            allowKeepExisting: Bool = false,
            explanation: LocalizedText? = nil
        ) {
            self.browsers = browsers
            self.urlSchemes = urlSchemes
            self.types = types
            self.allowKeepExisting = allowKeepExisting
            self.explanation = explanation
        }
    }

    public enum OpenTarget: Equatable, Sendable {
        case path(String)
        case bundleID(String)
        case url(URL)
    }

    public enum OpenCompletion: String, Sendable {
        /// The user ticks it off.
        case manual
        /// Completed when the item's validatePath exists.
        case validatePath
    }

    public let id: String
    public let kind: Kind
    public let mode: Mode
    public let title: LocalizedText?
    public let subtitle: LocalizedText?
    public let icon: IconSpec?
    public let buttonTitle: LocalizedText?
    public let required: Bool
    public let enabled: Bool
    public let timeout: Int
    public let validatePath: String?

    public init(
        id: String,
        kind: Kind,
        mode: Mode? = nil,
        title: LocalizedText? = nil,
        subtitle: LocalizedText? = nil,
        icon: IconSpec? = nil,
        buttonTitle: LocalizedText? = nil,
        required: Bool = true,
        enabled: Bool = true,
        timeout: Int = 600,
        validatePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mode = Self.effectiveMode(requested: mode, kind: kind)
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.buttonTitle = buttonTitle
        self.required = required
        self.enabled = enabled
        self.timeout = timeout
        self.validatePath = validatePath
    }

    /// defaultApps is always interactive (macOS prompts the user); open is
    /// inherently interactive; message is inherently automatic (there is
    /// nothing to interact with); the rest default to automatic.
    public static func effectiveMode(requested: Mode?, kind: Kind) -> Mode {
        switch kind {
        case .defaultApps, .open:
            return .interactive
        case .message:
            return .automatic
        case .wallpaper, .dock, .demoteUser:
            return requested ?? .automatic
        }
    }
}

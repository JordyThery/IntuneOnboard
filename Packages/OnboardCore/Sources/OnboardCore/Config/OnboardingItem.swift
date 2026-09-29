import Foundation

/// One onboarding step.
public struct OnboardingItem: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// Runs when shown.
        case automatic
        /// Runs when the user presses a button.
        case interactive
    }

    public enum Kind: Equatable, Sendable {
        /// Informational; completes when viewed.
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

    /// In onboarding, a single value is confirmed and several values are
    /// offered as a choice.
    public struct WallpaperSpec: Equatable, Sendable {
        public let sources: [Source]
        /// Only valid with a single source.
        public let sha256: String?
        /// Offers keeping the current wallpaper.
        public let allowKeepExisting: Bool

        public init(sources: [Source], sha256: String? = nil, allowKeepExisting: Bool = false) {
            self.sources = sources
            self.sha256 = sha256
            self.allowKeepExisting = allowKeepExisting
        }
    }

    public enum DockStrategy: String, Sendable, CaseIterable {
        /// Leave the Dock unchanged.
        case keep
        /// Add the configured items.
        case add
        /// Remove all items, then add the configured items.
        case replace
    }

    public struct DockSpec: Equatable, Sendable {
        /// Several strategies are offered as a choice; include `keep` to offer
        /// keeping the current Dock.
        public let strategies: [DockStrategy]
        /// Paths or `bundleid:` entries. Missing apps are skipped.
        public let items: [String]
        /// Seconds to wait for listed apps to be installed.
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
        /// Bundle ids for the `http` scheme.
        public let browsers: [String]
        /// Scheme to candidate bundle ids.
        public let urlSchemes: [String: [String]]
        /// UTI to candidate bundle ids.
        public let types: [String: [String]]
        /// Offers keeping the current handler.
        public let allowKeepExisting: Bool
        /// Shown before macOS asks the user to confirm.
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
        /// Completed when the user opens the target.
        case manual
        /// Completed when `validatePath` exists.
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

    /// `defaultApps` and `open` are always interactive, `message` always
    /// automatic; other kinds default to automatic.
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

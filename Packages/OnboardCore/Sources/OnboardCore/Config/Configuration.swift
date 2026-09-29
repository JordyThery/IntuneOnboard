import Foundation

/// The full parsed configuration for domain `be.jordythery.intuneonboard`.
public struct Configuration: Equatable, Sendable {
    /// The schema major version this build understands. Unknown versions
    /// refuse to run (validated, not silently ignored).
    public static let supportedSchemaVersion = 1

    /// The circled question mark in the lower right of the provisioning card.
    /// `url` becomes a QR code, so someone can reach the service desk from a
    /// Mac that has no browser and no signed-in user yet — which is the whole
    /// point during Setup Assistant.
    public struct Help: Equatable, Sendable {
        public let title: LocalizedText?
        public let message: LocalizedText?
        public let url: URL?

        public init(title: LocalizedText? = nil, message: LocalizedText? = nil, url: URL? = nil) {
            self.title = title
            self.message = message
            self.url = url
        }

        /// Nothing to show means no button at all.
        public var isEmpty: Bool {
            title == nil && message == nil && url == nil
        }
    }

    public struct Organization: Equatable, Sendable {
        public let name: String
        /// The identity mark in the window's header. Any icon source.
        public let logo: IconSpec?
        /// #RRGGBB. Tints the progress bar and controls.
        public let accentColor: String?
        public let supportText: LocalizedText?
        public let supportURL: URL?
        public let help: Help?

        public init(
            name: String,
            logo: IconSpec? = nil,
            accentColor: String? = nil,
            supportText: LocalizedText? = nil,
            supportURL: URL? = nil,
            help: Help? = nil
        ) {
            self.name = name
            self.logo = logo
            self.accentColor = accentColor
            self.supportText = supportText
            self.supportURL = supportURL
            self.help = help
        }
    }

    public struct Network: Equatable, Sendable {
        /// Preflight fails when unreachable (exit 13).
        public let requiredURLs: [URL]
        /// Logged only.
        public let warnURLs: [URL]
        public let timeoutSeconds: Int

        public init(requiredURLs: [URL] = [], warnURLs: [URL] = [], timeoutSeconds: Int = 30) {
            self.requiredURLs = requiredURLs
            self.warnURLs = warnURLs
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public struct Installomator: Equatable, Sendable {
        public let defaultOptions: [String]
        /// When true, updates only from a tagged GitHub release (never main),
        /// into a root-owned location, falling back to the bundled copy.

        public init(defaultOptions: [String] = InstallomatorOptions.bootstrapDefaults) {
            self.defaultOptions = defaultOptions
        }
    }

    public struct Provisioning: Equatable, Sendable {
        public let title: LocalizedText?
        public let message: LocalizedText?
        public let showDeviceInfo: Bool
        public let allowContinueOnError: Bool
        /// Names the Mac from device-derived tokens (`%serial%`, `%model%`…)
        /// before the items run. Device-derived only: there is no entry
        /// dialog, by decision.
        public let deviceNameTemplate: NameTemplate?
        public let items: [ProvisioningItem]

        public init(
            title: LocalizedText? = nil,
            message: LocalizedText? = nil,
            showDeviceInfo: Bool = true,
            allowContinueOnError: Bool = false,
            deviceNameTemplate: NameTemplate? = nil,
            items: [ProvisioningItem] = []
        ) {
            self.title = title
            self.message = message
            self.showDeviceInfo = showDeviceInfo
            self.allowContinueOnError = allowContinueOnError
            self.deviceNameTemplate = deviceNameTemplate
            self.items = items
        }
    }

    public struct Onboarding: Equatable, Sendable {
        /// Where the onboarding card sits, and whether anything else can
        /// be reached while it is up. Two values, because they are the two
        /// meaningfully different behaviours; anything else is a config
        /// error rather than a silent `center`.
        public enum WindowPosition: String, Equatable, Sendable, CaseIterable {
            /// An ordinary window, centred. Other apps stay reachable.
            case center
            /// A backdrop fills every screen beneath the onboarding, so
            /// nothing behind it can be seen or clicked. Lifted while an
            /// `open` step waits on the user — otherwise the app they were
            /// just told to sign into would be stranded behind it.
            case focus
        }

        public let title: LocalizedText?
        public let message: LocalizedText?
        public let items: [OnboardingItem]
        /// Opened when the user presses Done — the only post-run hook, by
        /// decision (no finishedScript, no finalAction).
        public let launchOnCompletion: OnboardingItem.OpenTarget?
        /// Hide other apps when the onboarding launches. Fires **once, at
        /// launch**: nothing stops the user opening something afterwards —
        /// use `windowPosition: focus` to actually hold the screen.
        /// Suppressed under dryRun: a dry run must not rearrange the
        /// user's session.
        public let hideOtherApps: Bool
        /// false removes ⌘Q, the close button and the minimize button until
        /// onboarding is done, and keeps the window above other apps —
        /// with no Dock icon to restore from, a minimized window would be
        /// unreachable. ⌃⌥⌘Q stays as the administrator's way out.
        public let allowQuit: Bool
        public let windowPosition: WindowPosition
        /// Fills the focus backdrop. nil uses the Mac's current desktop
        /// picture, so the backdrop reads as the Mac's own desktop rather
        /// than a foreign wall of colour. Ignored unless `windowPosition`
        /// is `focus`.
        public let background: IconSpec?
        /// Blurs the focus backdrop. Ignored unless `windowPosition` is
        /// `focus` — which is why it was skipped until focus mode existed.
        public let blur: Bool

        public init(
            title: LocalizedText? = nil,
            message: LocalizedText? = nil,
            items: [OnboardingItem] = [],
            launchOnCompletion: OnboardingItem.OpenTarget? = nil,
            hideOtherApps: Bool = true,
            allowQuit: Bool = true,
            windowPosition: WindowPosition = .center,
            background: IconSpec? = nil,
            blur: Bool = false
        ) {
            self.title = title
            self.message = message
            self.items = items
            self.launchOnCompletion = launchOnCompletion
            self.hideOtherApps = hideOtherApps
            self.allowQuit = allowQuit
            self.windowPosition = windowPosition
            self.background = background
            self.blur = blur
        }
    }

    public struct Logging: Equatable, Sendable {
        public let maxFileSizeMB: Int
        public let keepArchives: Int

        public init(maxFileSizeMB: Int = 10, keepArchives: Int = 3) {
            self.maxFileSizeMB = maxFileSizeMB
            self.keepArchives = keepArchives
        }
    }

    public let schemaVersion: Int
    /// A dry run on a real Mac. Both stages
    /// render everything and change nothing — provisioning items are simulated
    /// instead of executed, onboarding actions apply to an in-memory overlay,
    /// and no completion marker is ever written, so the run repeats on every
    /// respawn/login until the key is removed. Both UIs carry a visible
    /// DRY RUN badge so a forgotten key can't masquerade as a real run.
    public let dryRun: Bool
    public let organization: Organization?
    public let requireADE: Bool
    public let network: Network
    public let installomator: Installomator
    public let provisioning: Provisioning?
    public let onboarding: Onboarding?
    public let logging: Logging

    public init(
        schemaVersion: Int = Configuration.supportedSchemaVersion,
        dryRun: Bool = false,
        organization: Organization? = nil,
        requireADE: Bool = false,
        network: Network = Network(),
        installomator: Installomator = Installomator(),
        provisioning: Provisioning? = nil,
        onboarding: Onboarding? = nil,
        logging: Logging = Logging()
    ) {
        self.schemaVersion = schemaVersion
        self.dryRun = dryRun
        self.organization = organization
        self.requireADE = requireADE
        self.network = network
        self.installomator = installomator
        self.provisioning = provisioning
        self.onboarding = onboarding
        self.logging = logging
    }
}

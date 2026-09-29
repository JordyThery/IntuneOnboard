import Foundation

/// The parsed configuration for domain `be.jordythery.intuneonboard`.
public struct Configuration: Equatable, Sendable {
    /// Other schema versions are rejected.
    public static let supportedSchemaVersion = 1

    /// The help button. `url` is shown as a QR code.
    public struct Help: Equatable, Sendable {
        public let title: LocalizedText?
        public let message: LocalizedText?
        public let url: URL?

        public init(title: LocalizedText? = nil, message: LocalizedText? = nil, url: URL? = nil) {
            self.title = title
            self.message = message
            self.url = url
        }

        /// No button is shown when empty.
        public var isEmpty: Bool {
            title == nil && message == nil && url == nil
        }
    }

    public struct Organization: Equatable, Sendable {
        public let name: String
        public let logo: IconSpec?
        /// `#RRGGBB`.
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
        /// Preflight fails if any is unreachable (exit 13).
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

        public init(defaultOptions: [String] = InstallomatorOptions.bootstrapDefaults) {
            self.defaultOptions = defaultOptions
        }
    }

    public struct Provisioning: Equatable, Sendable {
        public let title: LocalizedText?
        public let message: LocalizedText?
        public let showDeviceInfo: Bool
        public let allowContinueOnError: Bool
        /// Applied before the items run.
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
        public enum WindowPosition: String, Equatable, Sendable, CaseIterable {
            /// A normal, centred window.
            case center
            /// A backdrop covers every screen behind the window. It is lifted
            /// while an `open` step is in progress.
            case focus
        }

        public let title: LocalizedText?
        public let message: LocalizedText?
        public let items: [OnboardingItem]
        /// Opened when the user presses Done.
        public let launchOnCompletion: OnboardingItem.OpenTarget?
        /// Hides other apps once, at launch. Not applied during a dry run.
        public let hideOtherApps: Bool
        /// When false, the window cannot be quit, closed or minimized, and
        /// stays in front, until all steps are done.
        public let allowQuit: Bool
        public let windowPosition: WindowPosition
        /// The `focus` backdrop image; nil uses the current wallpaper.
        public let background: IconSpec?
        /// Blurs the `focus` backdrop.
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
    /// Renders both stages without changing the Mac or writing completion
    /// markers. Both windows show a DRY RUN badge.
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

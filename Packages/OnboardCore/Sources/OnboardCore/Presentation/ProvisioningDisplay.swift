import Foundation

/// Everything the provisioning UI draws: the configuration supplies the static part
/// (order, titles, icons), the daemon's snapshot supplies the live part
/// (outcome, status, status text). A plain value type with no UI and no I/O, so
/// the merge rules are unit-testable and the views stay dumb.
public struct ProvisioningDisplay: Equatable, Sendable {
    /// Where the run is. `connecting` is UI-only: the daemon hasn't answered
    /// yet and there is no progress.json to fall back on.
    public enum Phase: String, Equatable, Sendable {
        case connecting
        case waitingForConfig
        case preflight
        case running
        case completed
        case completedWithErrors
        case preflightFailed

        public init(engineState: ProgressSnapshot.EngineState) {
            switch engineState {
            case .waitingForConfig: self = .waitingForConfig
            case .preflight: self = .preflight
            case .running: self = .running
            case .completed: self = .completed
            case .completedWithErrors: self = .completedWithErrors
            case .preflightFailed: self = .preflightFailed
            }
        }

        public var isFinished: Bool {
            switch self {
            case .completed, .completedWithErrors, .preflightFailed: true
            case .connecting, .waitingForConfig, .preflight, .running: false
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        /// Falls back to the item id when config carries no title.
        public let title: String
        public let subtitle: String?
        public let icon: IconSpec?
        public let outcome: ItemOutcome
        public let status: StatusKind
        /// Verbatim line from a script's `status:` output; overrides the
        /// localized status label when present.
        public let statusText: String?
        public let required: Bool

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            icon: IconSpec? = nil,
            outcome: ItemOutcome = .pending,
            status: StatusKind = .waiting,
            statusText: String? = nil,
            required: Bool = true
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.outcome = outcome
            self.status = status
            self.statusText = statusText
            self.required = required
        }
    }

    public struct Header: Equatable, Sendable {
        public let organizationName: String?
        public let logo: IconSpec?
        /// #RRGGBB from config; the UI tints itself with it.
        public let accentColor: String?
        /// nil means "use the built-in localized default".
        public let title: String?
        public let message: String?
        public let supportText: String?
        public let supportURL: URL?
        /// Drives the circled question mark and its QR code.
        public let help: Configuration.Help?

        public init(
            organizationName: String? = nil,
            logo: IconSpec? = nil,
            accentColor: String? = nil,
            title: String? = nil,
            message: String? = nil,
            supportText: String? = nil,
            supportURL: URL? = nil,
            help: Configuration.Help? = nil
        ) {
            self.organizationName = organizationName
            self.logo = logo
            self.accentColor = accentColor
            self.title = title
            self.message = message
            self.supportText = supportText
            self.supportURL = supportURL
            self.help = help
        }
    }

    public let phase: Phase
    public let header: Header
    /// In configuration order, disabled items removed.
    public let rows: [Row]
    public let deviceInfo: DeviceInfo?
    /// Config's `allowContinueOnError`: lets the user dismiss a failed run.
    public let allowContinueOnError: Bool
    /// Config's `dryRun`: the UI wears a badge so a dry run can never be
    /// mistaken for a real one.
    public let dryRun: Bool
    public let updatedAt: Date?
    /// When the run began — drives the elapsed time in "About this Mac".
    public let startedAt: Date?

    public init(
        phase: Phase,
        header: Header = Header(),
        rows: [Row] = [],
        deviceInfo: DeviceInfo? = nil,
        allowContinueOnError: Bool = false,
        dryRun: Bool = false,
        updatedAt: Date? = nil,
        startedAt: Date? = nil
    ) {
        self.phase = phase
        self.header = header
        self.rows = rows
        self.deviceInfo = deviceInfo
        self.allowContinueOnError = allowContinueOnError
        self.dryRun = dryRun
        self.updatedAt = updatedAt
        self.startedAt = startedAt
    }

    // MARK: - Derived

    public var totalCount: Int { rows.count }

    public var completedCount: Int {
        rows.filter { $0.outcome == .success || $0.outcome == .skipped }.count
    }

    public var failedCount: Int {
        rows.filter { $0.outcome == .failed }.count
    }

    /// Determinate progress once there are rows; before that the phase decides
    /// (nothing done while waiting, everything done once finished cleanly).
    public var fractionComplete: Double {
        guard totalCount > 0 else { return phase == .completed ? 1 : 0 }
        return Double(completedCount) / Double(totalCount)
    }

    /// The item being worked on, for the "what's happening now" line.
    public var currentRow: Row? {
        rows.first { $0.outcome == .running }
    }

    /// Retry is offered only when a finished run left failed items behind —
    /// the daemon refuses the request in any other state anyway.
    public var canRetry: Bool {
        phase == .completedWithErrors && failedCount > 0
    }

    // MARK: - Merge

    /// Builds the display from config + snapshot. Either may be missing: with
    /// no snapshot the rows render as pending, with no config the snapshot's
    /// ids stand in for titles (the daemon may hold a profile the app can't
    /// read yet).
    public static func make(
        configuration: Configuration?,
        snapshot: ProgressSnapshot?,
        deviceInfo: DeviceInfo? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> ProvisioningDisplay {
        let provisioning = configuration?.provisioning
        let organization = configuration?.organization

        let header = Header(
            organizationName: organization?.name,
            logo: organization?.logo,
            accentColor: organization?.accentColor,
            title: provisioning?.title?.resolved(preferredLanguages: preferredLanguages),
            message: provisioning?.message?.resolved(preferredLanguages: preferredLanguages),
            supportText: organization?.supportText?.resolved(preferredLanguages: preferredLanguages),
            supportURL: organization?.supportURL,
            help: organization?.help
        )

        let states = Dictionary(
            (snapshot?.items ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )

        let rows: [Row]
        if let items = provisioning?.items, !items.isEmpty {
            rows = items.filter(\.enabled).map { item in
                let state = states[item.id]
                return Row(
                    id: item.id,
                    title: item.title?.resolved(preferredLanguages: preferredLanguages) ?? item.id,
                    subtitle: item.subtitle?.resolved(preferredLanguages: preferredLanguages),
                    icon: item.icon,
                    outcome: state?.outcome ?? .pending,
                    status: state?.status ?? .waiting,
                    statusText: state?.statusText,
                    required: item.required
                )
            }
        } else {
            rows = (snapshot?.items ?? []).map { state in
                Row(
                    id: state.id,
                    title: state.id,
                    outcome: state.outcome,
                    status: state.status,
                    statusText: state.statusText
                )
            }
        }

        return ProvisioningDisplay(
            phase: snapshot.map { Phase(engineState: $0.engineState) } ?? .connecting,
            header: header,
            rows: rows,
            deviceInfo: (provisioning?.showDeviceInfo ?? false) ? deviceInfo : nil,
            allowContinueOnError: provisioning?.allowContinueOnError ?? false,
            dryRun: configuration?.dryRun ?? false,
            updatedAt: snapshot?.updatedAt,
            startedAt: snapshot?.startedAt
        )
    }
}

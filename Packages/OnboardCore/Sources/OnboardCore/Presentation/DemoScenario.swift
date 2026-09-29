import Foundation

/// A scripted run for `--demo provisioning`: a fixed configuration and a
/// timeline computed from elapsed time. One item fails; retrying succeeds.
public enum DemoScenario {
    public struct Step: Equatable, Sendable {
        public let id: String
        /// Seconds from the start of the run.
        public let start: Double
        public let duration: Double
        public let runningStatus: StatusKind
        public let outcome: ItemOutcome
        public let status: StatusKind
        /// Status text while running, as from a script's `status:` line.
        public let statusText: String?

        var end: Double { start + duration }
    }

    /// Preflight duration, before the first item.
    public static let preflightSeconds = 2.0

    public static let failingStepID = "privileges"

    public static let steps: [Step] = [
        Step(id: "rosetta", start: 2, duration: 2,
             runningStatus: .installing, outcome: .skipped, status: .notNeeded, statusText: nil),
        Step(id: "googlechrome", start: 4, duration: 5,
             runningStatus: .downloading, outcome: .success, status: .installed, statusText: nil),
        Step(id: "microsoftdefender", start: 9, duration: 5,
             runningStatus: .downloading, outcome: .success, status: .installed, statusText: nil),
        Step(id: "privileges", start: 14, duration: 4,
             runningStatus: .downloading, outcome: .failed, status: .downloadFailed, statusText: nil),
        Step(id: "filevault", start: 18, duration: 3,
             runningStatus: .running, outcome: .success, status: .done,
             statusText: "Enabling FileVault deferred enrollment"),
        Step(id: "finalize", start: 21, duration: 2,
             runningStatus: .running, outcome: .success, status: .done,
             statusText: "Writing the completion marker"),
    ]

    public static var totalSeconds: Double {
        steps.map(\.end).max() ?? preflightSeconds
    }

    /// Where a retry resumes: the start of the failing item.
    public static var retryRebaseSeconds: Double {
        steps.first { $0.id == failingStepID }?.start ?? 0
    }

    // MARK: - Timeline

    public static func snapshot(atElapsed seconds: Double, retried: Bool = false) -> ProgressSnapshot {
        guard seconds >= preflightSeconds else {
            return ProgressSnapshot(
                engineState: .preflight,
                items: steps.map { ProgressSnapshot.Item(id: $0.id, outcome: .pending, status: .waiting) }
            )
        }

        let items = steps.map { step -> ProgressSnapshot.Item in
            let outcome = resolvedOutcome(for: step, retried: retried)
            let status = resolvedStatus(for: step, retried: retried)

            if seconds < step.start {
                return ProgressSnapshot.Item(id: step.id, outcome: .pending, status: .waiting)
            }
            if seconds < step.end {
                return ProgressSnapshot.Item(
                    id: step.id,
                    outcome: .running,
                    status: step.runningStatus,
                    statusText: step.statusText
                )
            }
            return ProgressSnapshot.Item(id: step.id, outcome: outcome, status: status)
        }

        let finished = seconds >= totalSeconds
        let anyFailed = items.contains { $0.outcome == .failed }
        return ProgressSnapshot(
            engineState: finished ? (anyFailed ? .completedWithErrors : .completed) : .running,
            items: items
        )
    }

    private static func resolvedOutcome(for step: Step, retried: Bool) -> ItemOutcome {
        retried && step.id == failingStepID ? .success : step.outcome
    }

    private static func resolvedStatus(for step: Step, retried: Bool) -> StatusKind {
        retried && step.id == failingStepID ? .installed : step.status
    }

    // MARK: - Configuration

    /// One item of every kind, with titles in two languages on one item.
    public static func configuration() -> Configuration {
        Configuration(
            organization: Configuration.Organization(
                name: "Demo Organization",
                logo: .symbol("building.2.crop.circle.fill"),
                accentColor: "#0F6CBD",
                help: Configuration.Help(
                    title: LocalizedText(plain: "Need a hand?"),
                    message: LocalizedText(plain: "Scan to reach the **IT service desk**."),
                    url: URL(string: "https://example.com/support")
                )
            ),
            provisioning: Configuration.Provisioning(
                title: LocalizedText(localized: [
                    "en": "Setting up your Mac",
                    "nl": "Je Mac wordt ingesteld",
                ]),
                message: LocalizedText(localized: [
                    "en": "This takes a few minutes. Leave the Mac plugged in and connected to the network.",
                    "nl": "Dit duurt enkele minuten. Laat de Mac aangesloten op stroom en netwerk.",
                ]),
                showDeviceInfo: true,
                items: [
                    ProvisioningItem(
                        id: "rosetta",
                        kind: .script(.init(source: .inline("/usr/sbin/softwareupdate --install-rosetta --agree-to-license"))),
                        title: LocalizedText(plain: "Rosetta 2"),
                        subtitle: LocalizedText(plain: "Intel app support"),
                        icon: .symbol("cpu")
                    ),
                    ProvisioningItem(
                        id: "googlechrome",
                        kind: .installomator(label: "googlechrome", options: []),
                        title: LocalizedText(plain: "Google Chrome"),
                        icon: .remote(URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Google_Chrome_icon_%28February_2022%29.svg/240px-Google_Chrome_icon_%28February_2022%29.svg.png")!)
                    ),
                    ProvisioningItem(
                        id: "microsoftdefender",
                        kind: .installomator(label: "microsoftdefender", options: []),
                        title: LocalizedText(plain: "Microsoft Defender"),
                        subtitle: LocalizedText(plain: "Endpoint protection"),
                        icon: .symbol("shield.lefthalf.filled")
                    ),
                    ProvisioningItem(
                        id: "privileges",
                        kind: .installomator(label: "privileges", options: []),
                        title: LocalizedText(plain: "Privileges"),
                        subtitle: LocalizedText(plain: "Temporary admin rights"),
                        icon: .symbol("key.fill")
                    ),
                    ProvisioningItem(
                        id: "filevault",
                        kind: .script(.init(source: .inline("echo status: configuring"))),
                        title: LocalizedText(plain: "Disk encryption"),
                        icon: .symbol("lock.shield")
                    ),
                    ProvisioningItem(
                        id: "finalize",
                        kind: .awaitPath(path: "/var/db/.AppleSetupDone", condition: .exists),
                        title: LocalizedText(plain: "Finishing up"),
                        icon: .symbol("checkmark.seal"),
                        required: false
                    ),
                ]
            )
        )
    }
}

/// Drives `DemoScenario` from the clock. Retry rewinds to the failing item,
/// which then succeeds.
public actor DemoProgressSource: ProgressProviding {
    private var startedAt = ContinuousClock.now
    private var elapsedOffset = 0.0
    private var retried = false

    public init() {}

    public func currentSnapshot() async -> ProgressSnapshot? {
        let seconds = elapsed
        let base = DemoScenario.snapshot(atElapsed: seconds, retried: retried)
        // A start time, for the elapsed time in "About this Mac".
        return ProgressSnapshot(
            engineState: base.engineState,
            items: base.items,
            startedAt: Date.now.addingTimeInterval(-seconds)
        )
    }

    public func requestRetry() async -> Bool {
        guard !retried else { return false }
        retried = true
        startedAt = .now
        elapsedOffset = DemoScenario.retryRebaseSeconds
        return true
    }

    private var elapsed: Double {
        let components = (ContinuousClock.now - startedAt).components
        return elapsedOffset + Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

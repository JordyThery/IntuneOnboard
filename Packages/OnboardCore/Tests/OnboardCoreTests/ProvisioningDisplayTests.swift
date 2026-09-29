import Foundation
import Testing
@testable import OnboardCore

@Suite struct ProvisioningDisplayTests {
    private func configuration(
        showDeviceInfo: Bool = false,
        allowContinueOnError: Bool = false,
        items: [ProvisioningItem]? = nil
    ) -> Configuration {
        Configuration(
            organization: Configuration.Organization(
                name: "Contoso",
                logo: .symbol("building.2"),
                accentColor: "#0F6CBD",
                supportText: LocalizedText(localized: ["en": "Call IT", "nl": "Bel IT"]),
                supportURL: URL(string: "https://example.com/help")
            ),
            provisioning: Configuration.Provisioning(
                title: LocalizedText(localized: ["en": "Setting up", "nl": "Instellen"]),
                message: LocalizedText(plain: "Hang on"),
                showDeviceInfo: showDeviceInfo,
                allowContinueOnError: allowContinueOnError,
                items: items ?? [
                    ProvisioningItem(
                        id: "chrome",
                        kind: .installomator(label: "googlechrome", options: []),
                        title: LocalizedText(localized: ["en": "Chrome", "nl": "Chrome-browser"]),
                        subtitle: LocalizedText(plain: "Browser"),
                        icon: .symbol("globe")
                    ),
                    ProvisioningItem(id: "defender", kind: .installomator(label: "microsoftdefender", options: [])),
                    ProvisioningItem(
                        id: "optional-thing",
                        kind: .wait(seconds: 1, message: nil),
                        required: false
                    ),
                ]
            )
        )
    }

    private let deviceInfo = DeviceInfo(
        computerName: "MacBook-Air",
        modelIdentifier: "Mac15,12",
        serialNumber: "C02XX1XXJG5H",
        osVersion: "Version 15.6"
    )

    @Test func mergesConfigOrderWithSnapshotState() {
        let snapshot = ProgressSnapshot(engineState: .running, items: [
            // Out of order: configuration order is used.
            .init(id: "defender", outcome: .running, status: .downloading),
            .init(id: "chrome", outcome: .success, status: .installed),
        ])
        let display = ProvisioningDisplay.make(
            configuration: configuration(),
            snapshot: snapshot,
            preferredLanguages: ["en"]
        )

        #expect(display.rows.map(\.id) == ["chrome", "defender", "optional-thing"])
        #expect(display.rows[0].outcome == .success)
        #expect(display.rows[0].title == "Chrome")
        #expect(display.rows[0].subtitle == "Browser")
        #expect(display.rows[1].outcome == .running)
        // No snapshot entry: pending.
        #expect(display.rows[2].outcome == .pending)
        #expect(display.rows[2].required == false)
        #expect(display.phase == .running)
    }

    @Test func resolvesLocalizedTextAgainstPreferredLanguages() {
        let display = ProvisioningDisplay.make(
            configuration: configuration(),
            snapshot: nil,
            preferredLanguages: ["nl-BE", "en"]
        )
        #expect(display.header.title == "Instellen")
        #expect(display.header.supportText == "Bel IT")
        #expect(display.rows[0].title == "Chrome-browser")
    }

    @Test func fallsBackToItemIDWhenConfigHasNoTitle() {
        let display = ProvisioningDisplay.make(configuration: configuration(), snapshot: nil)
        #expect(display.rows[1].title == "defender")
    }

    @Test func disabledItemsNeverReachTheUI() {
        let configuration = configuration(items: [
            ProvisioningItem(id: "on", kind: .wait(seconds: 1, message: nil)),
            ProvisioningItem(id: "off", kind: .wait(seconds: 1, message: nil), enabled: false),
        ])
        let display = ProvisioningDisplay.make(configuration: configuration, snapshot: nil)
        #expect(display.rows.map(\.id) == ["on"])
    }

    @Test func noSnapshotMeansConnecting() {
        let display = ProvisioningDisplay.make(configuration: configuration(), snapshot: nil)
        #expect(display.phase == .connecting)
        #expect(display.rows.allSatisfy { $0.outcome == .pending })
        #expect(display.fractionComplete == 0)
    }

    /// Without a configuration, item ids are used as titles.
    @Test func noConfigFallsBackToSnapshotIDs() {
        let snapshot = ProgressSnapshot(engineState: .running, items: [
            .init(id: "chrome", outcome: .success, status: .installed),
        ])
        let display = ProvisioningDisplay.make(configuration: nil, snapshot: snapshot)
        #expect(display.rows.map(\.id) == ["chrome"])
        #expect(display.rows[0].title == "chrome")
        #expect(display.header.organizationName == nil)
    }

    @Test func deviceInfoOnlyWhenConfigAsksForIt() {
        let hidden = ProvisioningDisplay.make(
            configuration: configuration(showDeviceInfo: false),
            snapshot: nil,
            deviceInfo: deviceInfo
        )
        #expect(hidden.deviceInfo == nil)

        let shown = ProvisioningDisplay.make(
            configuration: configuration(showDeviceInfo: true),
            snapshot: nil,
            deviceInfo: deviceInfo
        )
        #expect(shown.deviceInfo == deviceInfo)
    }

    @Test func skippedCountsAsCompleteAndProgressIsAFraction() {
        let snapshot = ProgressSnapshot(engineState: .running, items: [
            .init(id: "chrome", outcome: .success, status: .installed),
            .init(id: "defender", outcome: .skipped, status: .notNeeded),
            .init(id: "optional-thing", outcome: .running, status: .waiting),
        ])
        let display = ProvisioningDisplay.make(configuration: configuration(), snapshot: snapshot)
        #expect(display.completedCount == 2)
        #expect(display.totalCount == 3)
        #expect(abs(display.fractionComplete - 2.0 / 3.0) < 0.0001)
        #expect(display.currentRow?.id == "optional-thing")
    }

    @Test func retryOnlyOfferedOnAFinishedRunWithFailures() {
        let failing = ProgressSnapshot.Item(id: "chrome", outcome: .failed, status: .downloadFailed)

        let running = ProvisioningDisplay.make(
            configuration: configuration(),
            snapshot: ProgressSnapshot(engineState: .running, items: [failing])
        )
        #expect(!running.canRetry)

        let finished = ProvisioningDisplay.make(
            configuration: configuration(),
            snapshot: ProgressSnapshot(engineState: .completedWithErrors, items: [failing])
        )
        #expect(finished.canRetry)
        #expect(finished.failedCount == 1)

        let clean = ProvisioningDisplay.make(
            configuration: configuration(),
            snapshot: ProgressSnapshot(engineState: .completed, items: [
                .init(id: "chrome", outcome: .success, status: .installed),
            ])
        )
        #expect(!clean.canRetry)
        #expect(clean.phase.isFinished)
    }

    @Test func statusTextRidesAlongForScriptOutput() {
        let snapshot = ProgressSnapshot(engineState: .running, items: [
            .init(id: "chrome", outcome: .running, status: .running, statusText: "Copying to /Applications"),
        ])
        let display = ProvisioningDisplay.make(configuration: configuration(), snapshot: snapshot)
        #expect(display.rows[0].statusText == "Copying to /Applications")
    }

    @Test func allowContinueOnErrorIsCarriedThrough() {
        let display = ProvisioningDisplay.make(
            configuration: configuration(allowContinueOnError: true),
            snapshot: nil
        )
        #expect(display.allowContinueOnError)
    }

    @Test func everyEngineStateMapsToAPhase() {
        let expected: [ProgressSnapshot.EngineState: ProvisioningDisplay.Phase] = [
            .waitingForConfig: .waitingForConfig,
            .preflight: .preflight,
            .running: .running,
            .completed: .completed,
            .completedWithErrors: .completedWithErrors,
            .preflightFailed: .preflightFailed,
        ]
        for (state, phase) in expected {
            #expect(ProvisioningDisplay.Phase(engineState: state) == phase)
        }
        #expect(ProvisioningDisplay.Phase.preflightFailed.isFinished)
        #expect(!ProvisioningDisplay.Phase.connecting.isFinished)
    }
}

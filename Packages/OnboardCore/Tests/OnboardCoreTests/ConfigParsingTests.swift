import CoreImage
import Foundation
import Testing
@testable import OnboardCore

@Suite struct ConfigParsingTests {
    /// Mirrors the §10 example configuration.
    static func exampleRoot() -> [String: Any] {
        [
            "organization": [
                "name": "Contoso",
                "logo": "/Library/Application Support/Contoso/logo.png",
                "supportText": ["en": "Questions? Contact IT.", "nl": "Vragen? Contacteer IT."],
            ] as [String: Any],
            "requireADE": false,
            "network": [
                "warnURLs": ["https://officecdn.microsoft.com"],
            ] as [String: Any],
            "provisioning": [
                "title": ["en": "Installing apps", "nl": "Installeren van apps"],
                "showDeviceInfo": true,
                "items": [
                    [
                        "id": "m365",
                        "kind": "installomator",
                        "label": "microsoftofficebusinesspro",
                        "title": "Microsoft 365",
                        "icon": "symbol:square.grid.2x2",
                        "validatePath": "/Applications/Microsoft Outlook.app",
                    ] as [String: Any],
                    [
                        "id": "edge",
                        "kind": "installomator",
                        "label": "microsoftedge",
                        "title": "Microsoft Edge",
                    ] as [String: Any],
                    [
                        "id": "pause",
                        "kind": "wait",
                        "seconds": 30,
                    ] as [String: Any],
                ],
            ] as [String: Any],
            "onboarding": [
                "items": [
                    [
                        "id": "wallpaper",
                        "kind": "wallpaper",
                        "source": "/Library/Application Support/Contoso/company-wallpaper.jpg",
                    ] as [String: Any],
                    [
                        "id": "dock",
                        "kind": "dock",
                        "dockStrategy": "replace",
                        "waitForItemsTimeout": 300,
                        "items": ["/System/Applications/Apps.app", "/Applications/Microsoft Edge.app"],
                    ] as [String: Any],
                    [
                        "id": "defaults",
                        "kind": "defaultApps",
                        "browser": "com.microsoft.edgemac",
                        "urlSchemes": ["mailto": "com.microsoft.Outlook"],
                    ] as [String: Any],
                    [
                        "id": "register",
                        "kind": "open",
                        "target": "/Applications/Company Portal.app",
                        "completion": "manual",
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
    }

    @Test func parsesExampleConfiguration() throws {
        let (configuration, errors) = ConfigParser.parse(Self.exampleRoot())
        #expect(errors.isEmpty, "\(errors)")
        let config = try #require(configuration)

        #expect(config.schemaVersion == 1)
        #expect(config.organization?.name == "Contoso")
        #expect(config.network.warnURLs.count == 1)
        #expect(config.installomator.defaultOptions == InstallomatorOptions.bootstrapDefaults)

        let items = try #require(config.provisioning?.items)
        #expect(items.count == 3)
        #expect(items[0].id == "m365")
        if case .installomator(let label, let options) = items[0].kind {
            #expect(label == "microsoftofficebusinesspro")
            #expect(options.isEmpty)
        } else {
            Issue.record("expected installomator kind")
        }
        #expect(items[0].timeout == 1800)
        #expect(items[2].timeout == 30) // wait defaults to its own duration

        let onboarding = try #require(config.onboarding?.items)
        #expect(onboarding.count == 4)
        #expect(onboarding[2].mode == .interactive) // defaultApps forced interactive
        #expect(onboarding[1].mode == .automatic)
    }

    /// A key nobody reads is silently inert — a misspelling behaves exactly
    /// like the key never being set, and no one is told. On an otherwise
    /// clean parse, every unread key is a hard error naming its exact path.
    @Test func unreadKeysAreErrorsOnACleanParse() throws {
        var root = Self.exampleRoot()
        root["allowContinueOnErorr"] = true // root-level typo
        var onboarding = root["onboarding"] as! [String: Any]
        var items = onboarding["items"] as! [[String: Any]]
        items[1]["restartDok"] = false // nested typo, inside a dock item
        onboarding["items"] = items
        root["onboarding"] = onboarding

        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        #expect(errors.count == 2, "\(errors)")
        #expect(errors.contains { $0.path == "config.allowContinueOnErorr" && $0.kind == .unknownKey })
        #expect(errors.contains { $0.path == "config.onboarding.items[1].restartDok" && $0.kind == .unknownKey })
    }

    /// Apple's profile-metadata namespace is exempt at the root: the MDM
    /// transport may leave a PayloadUUID behind in managed preferences, and
    /// no admin wrote it. Nested, Payload* is a typo like any other.
    @Test func payloadMetadataAtTheRootIsTolerated() throws {
        var root = Self.exampleRoot()
        root["PayloadType"] = "be.jordythery.intuneonboard"
        root["PayloadUUID"] = "B7E4D9C1-3F62-4A8E-9D05-7C1E4B2A6F31"
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        #expect(configuration != nil)

        var nested = Self.exampleRoot()
        var organization = nested["organization"] as! [String: Any]
        organization["PayloadStray"] = true
        nested["organization"] = organization
        let (_, nestedErrors) = ConfigParser.parse(nested)
        #expect(nestedErrors.contains { $0.path == "config.organization.PayloadStray" && $0.kind == .unknownKey })
    }

    /// The audit stays silent when the parse already failed: a broken item
    /// legitimately leaves its keys unread, and unknown-key noise on top
    /// would bury the error that actually needs fixing.
    @Test func unreadKeysStayQuietWhenTheParseAlreadyFailed() throws {
        var root = Self.exampleRoot()
        root["allowContinueOnErorr"] = true
        var provisioning = root["provisioning"] as! [String: Any]
        var items = provisioning["items"] as! [[String: Any]]
        items[0]["kind"] = "polciy" // unknown kind: the real error
        provisioning["items"] = items
        root["provisioning"] = provisioning

        let (_, errors) = ConfigParser.parse(root)
        #expect(errors.contains { $0.kind == .unknownKind("polciy") })
        #expect(!errors.contains { $0.kind == .unknownKey }, "\(errors)")
    }

    /// The onboarding's shape rule: scalar means confirm, array means choose.
    /// A scalar parses as a one-element list so the UI branches on count.
    @Test func scalarConfirmsArrayChooses() throws {
        var root = Self.exampleRoot()
        root["onboarding"] = [
            "items": [
                [
                    "id": "wallpaper",
                    "kind": "wallpaper",
                    "source": ["https://example.com/a.jpg", "https://example.com/b.jpg"],
                    "allowKeepExisting": true,
                ] as [String: Any],
                [
                    "id": "dock",
                    "kind": "dock",
                    "dockStrategy": ["add", "replace"],
                    "items": ["/System/Applications/Apps.app"],
                ] as [String: Any],
                [
                    "id": "defaults",
                    "kind": "defaultApps",
                    "browser": ["com.microsoft.edgemac", "com.apple.Safari"],
                    "urlSchemes": ["mailto": ["com.microsoft.Outlook", "com.apple.mail"]],
                    "allowKeepExisting": true,
                ] as [String: Any],
            ],
        ] as [String: Any]

        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        let items = try #require(configuration?.onboarding?.items)

        guard case .wallpaper(let wallpaper) = items[0].kind else {
            Issue.record("expected wallpaper"); return
        }
        #expect(wallpaper.sources.count == 2)
        #expect(wallpaper.allowKeepExisting)

        guard case .dock(let dock) = items[1].kind else {
            Issue.record("expected dock"); return
        }
        #expect(dock.strategies == [.add, .replace])

        guard case .defaultApps(let apps) = items[2].kind else {
            Issue.record("expected defaultApps"); return
        }
        #expect(apps.browsers == ["com.microsoft.edgemac", "com.apple.Safari"])
        #expect(apps.urlSchemes["mailto"] == ["com.microsoft.Outlook", "com.apple.mail"])
        #expect(apps.allowKeepExisting)
    }

    @Test func invalidDockStrategyIsAConfigError() {
        var root = Self.exampleRoot()
        root["onboarding"] = [
            "items": [[
                "id": "dock", "kind": "dock",
                "dockStrategy": "obliterate",
                "items": [] as [String],
            ] as [String: Any]],
        ] as [String: Any]
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        #expect(errors.contains { $0.path.contains("dockStrategy") })
    }

    /// One hash cannot vouch for several files.
    @Test func sha256WithSeveralWallpaperSourcesIsRejected() {
        let items = [OnboardingItem(
            id: "w",
            kind: .wallpaper(.init(
                sources: [.path("/a.jpg"), .path("/b.jpg")],
                sha256: String(repeating: "0", count: 64)
            ))
        )]
        let errors = ConfigValidator.validate(Configuration(
            onboarding: .init(title: nil, message: nil, items: items)
        ))
        #expect(errors.contains { $0.kind == .unreachableCombination("sha256 requires exactly one wallpaper source") })
    }

    /// The onboarding's only post-run hook: Done opens this.
    @Test func launchOnCompletionParsesEveryTargetForm() throws {
        for (raw, expected) in [
            ("bundleid:com.microsoft.CompanyPortalMac", OnboardingItem.OpenTarget.bundleID("com.microsoft.CompanyPortalMac")),
            ("/Applications/Safari.app", .path("/Applications/Safari.app")),
            ("https://example.com/welcome", .url(URL(string: "https://example.com/welcome")!)),
        ] {
            var root = Self.exampleRoot()
            var onboarding = root["onboarding"] as! [String: Any]
            onboarding["launchOnCompletion"] = raw
            root["onboarding"] = onboarding
            let (configuration, errors) = ConfigParser.parse(root)
            #expect(errors.isEmpty, "\(errors)")
            #expect(configuration?.onboarding?.launchOnCompletion == expected)
        }

        // Garbage is a config error, same rule as the open kind's target.
        var root = Self.exampleRoot()
        var onboarding = root["onboarding"] as! [String: Any]
        onboarding["launchOnCompletion"] = "not a target"
        root["onboarding"] = onboarding
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        #expect(errors.contains { $0.path.contains("launchOnCompletion") })
    }

    /// The dry-run key, defaulting off.
    @Test func dryRunKeyParsesAndDefaultsOff() throws {
        let (defaulted, _) = ConfigParser.parse(Self.exampleRoot())
        #expect(defaulted?.dryRun == false)

        var root = Self.exampleRoot()
        root["dryRun"] = true
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        #expect(configuration?.dryRun == true)
    }

    /// The onboarding window keys, defaults included.
    @Test func onboardingWindowKeysParseWithTheirDefaults() throws {
        let (defaulted, _) = ConfigParser.parse(Self.exampleRoot())
        #expect(defaulted?.onboarding?.hideOtherApps == true)
        #expect(defaulted?.onboarding?.allowQuit == true)
        #expect(defaulted?.onboarding?.windowPosition == .center)
        #expect(defaulted?.onboarding?.background == nil)
        #expect(defaulted?.onboarding?.blur == false)

        var root = Self.exampleRoot()
        var onboarding = root["onboarding"] as! [String: Any]
        onboarding["hideOtherApps"] = false
        onboarding["allowQuit"] = false
        onboarding["windowPosition"] = "focus"
        onboarding["background"] = "/Library/Desktop Pictures/corp.jpg"
        onboarding["blur"] = true
        root["onboarding"] = onboarding
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        #expect(configuration?.onboarding?.hideOtherApps == false)
        #expect(configuration?.onboarding?.allowQuit == false)
        #expect(configuration?.onboarding?.windowPosition == .focus)
        #expect(configuration?.onboarding?.background == .path("/Library/Desktop Pictures/corp.jpg"))
        #expect(configuration?.onboarding?.blur == true)
    }

    /// `left`/`right` are real reference values we don't implement; silently
    /// centring a profile that asked for them would be a lie.
    @Test func unsupportedWindowPositionsAreConfigErrors() throws {
        for raw in ["left", "right", "focussed"] {
            var root = Self.exampleRoot()
            var onboarding = root["onboarding"] as! [String: Any]
            onboarding["windowPosition"] = raw
            root["onboarding"] = onboarding
            let (configuration, errors) = ConfigParser.parse(root)
            #expect(configuration == nil, "\(raw) should not parse")
            #expect(errors.contains { $0.path.contains("windowPosition") })
        }
    }

    /// A template typo must fail the profile at parse time — the alternative
    /// is a fleet named wrong.
    @Test func deviceNameTemplateParsesAndRejectsTypos() throws {
        var root = Self.exampleRoot()
        var provisioning = root["provisioning"] as! [String: Any]
        provisioning["deviceNameTemplate"] = "L9P-%serial:-6%"
        root["provisioning"] = provisioning
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        #expect(configuration?.provisioning?.deviceNameTemplate?.raw == "L9P-%serial:-6%")

        provisioning["deviceNameTemplate"] = "L9P-%serail%"
        root["provisioning"] = provisioning
        let (rejected, typoErrors) = ConfigParser.parse(root)
        #expect(rejected == nil)
        #expect(typoErrors.contains { $0.path.contains("deviceNameTemplate") })
    }

    /// A message step is a title and a message, nothing else. The old media
    /// keys are gone, so a profile still carrying them fails the unknown-key
    /// audit instead of silently losing its hero image.
    @Test func messageStepParsesAndRejectsTheRetiredMediaKeys() throws {
        var root = Self.exampleRoot()
        root["onboarding"] = [
            "items": [
                ["id": "welcome", "kind": "message"] as [String: Any],
            ],
        ] as [String: Any]

        let (configuration, errors) = ConfigParser.parse(root)
        #expect(errors.isEmpty, "\(errors)")
        let items = try #require(configuration?.onboarding?.items)
        #expect(items[0].kind == .message)
        #expect(items[0].mode == .automatic)

        var stale = Self.exampleRoot()
        stale["onboarding"] = ["items": [[
            "id": "video", "kind": "message", "movie": "https://example.com/welcome.mp4",
        ] as [String: Any]]] as [String: Any]
        let (rejected, staleErrors) = ConfigParser.parse(stale)
        #expect(rejected == nil)
        #expect(staleErrors.contains { $0.path.hasSuffix(".movie") && $0.kind == .unknownKey })
    }

    @Test func rejectsUnknownSchemaVersion() {
        var root = Self.exampleRoot()
        root["schemaVersion"] = 2
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        #expect(errors.contains { $0.kind == .unsupportedSchemaVersion(found: 2, supported: 1) })
    }

    @Test func reportsUnknownKindWithPath() {
        var root = Self.exampleRoot()
        var provisioning = root["provisioning"] as! [String: Any]
        provisioning["items"] = [["id": "x", "kind": "frobnicate"] as [String: Any]]
        root["provisioning"] = provisioning

        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        let error = errors.first { $0.kind == .unknownKind("frobnicate") }
        #expect(error?.path == "config.provisioning.items[0].kind")
    }

    @Test func reportsForbiddenDebugOption() {
        var root = Self.exampleRoot()
        root["installomator"] = ["defaultOptions": ["NOTIFY=silent", "DEBUG=1"]] as [String: Any]
        let (configuration, errors) = ConfigParser.parse(root)
        #expect(configuration == nil)
        #expect(errors.contains { $0.kind == .invalidOption("DEBUG=1", .debugForbidden) })
    }

    @Test func reportsTypeMismatchWithPath() {
        var root = Self.exampleRoot()
        root["schemaVersion"] = "one"
        let (_, errors) = ConfigParser.parse(root)
        #expect(errors.contains { $0.path == "config.schemaVersion" })
    }

    @Test func scriptNeedsExactlyOneSource() {
        var root: [String: Any] = ["provisioning": ["items": [
            ["id": "s1", "kind": "script"] as [String: Any],
        ]] as [String: Any]]
        var (_, errors) = ConfigParser.parse(root)
        #expect(errors.contains { $0.kind == .scriptSourceMissing })

        root = ["provisioning": ["items": [
            ["id": "s2", "kind": "script", "script": "echo hi", "path": "/tmp/x.sh"] as [String: Any],
        ]] as [String: Any]]
        (_, errors) = ConfigParser.parse(root)
        #expect(errors.contains { $0.kind == .scriptSourceMissing })
    }

    @Test func rejectsInvalidAccentColorAndBadID() {
        var root = Self.exampleRoot()
        var organization = root["organization"] as! [String: Any]
        organization["accentColor"] = "red"
        root["organization"] = organization
        var provisioning = root["provisioning"] as! [String: Any]
        provisioning["items"] = [["id": "bad id!", "kind": "wait", "seconds": 5] as [String: Any]]
        root["provisioning"] = provisioning

        let (_, errors) = ConfigParser.parse(root)
        #expect(errors.contains { $0.kind == .invalidAccentColor("red") })
        #expect(errors.contains { $0.kind == .invalidID("bad id!") })
    }
}

@Suite struct BrandingAndHelpParsingTests {
    private func parse(_ organization: [String: Any]) throws -> Configuration {
        try ConfigLoader.parseAndValidate(
            ["schemaVersion": 1, "organization": organization],
            fileChecks: .init(attributesOfItem: { _ in (ownerUID: 0, permissions: 0o755) })
        )
    }

    @Test func logoAcceptsEveryIconSource() throws {
        let remote = try parse(["name": "Contoso", "logo": "https://example.com/logo.png"])
        #expect(remote.organization?.logo == .remote(URL(string: "https://example.com/logo.png")!))

        let path = try parse(["name": "Contoso", "logo": "/Library/Contoso/logo.png"])
        #expect(path.organization?.logo == .path("/Library/Contoso/logo.png"))

        let named = try parse(["name": "Contoso", "logo": "name:Logo"])
        #expect(named.organization?.logo == .named("Logo"))
    }

    /// The `name:` icon source resolves NSImage named images.
    @Test func namedIconsParse() {
        #expect(IconSpec(configString: "name:NSComputer") == .named("NSComputer"))
        #expect(IconSpec(configString: "name:") == nil)
    }

    @Test func helpParsesTitleMessageAndQRURL() throws {
        let configuration = try parse([
            "name": "Contoso",
            "help": [
                "title": "Need a hand?",
                "message": "Scan to reach **IT**.",
                "url": "https://example.com/support",
            ],
        ])
        let help = try #require(configuration.organization?.help)
        #expect(help.title?.resolved(preferredLanguages: ["en"]) == "Need a hand?")
        #expect(help.message?.resolved(preferredLanguages: ["en"]) == "Scan to reach **IT**.")
        #expect(help.url?.absoluteString == "https://example.com/support")
        #expect(!help.isEmpty)
    }

    /// No help keys means no question mark button at all.
    @Test func absentHelpIsNil() throws {
        #expect(try parse(["name": "Contoso"]).organization?.help == nil)
    }

    @Test func helpURLMustBeHTTPS() {
        #expect(throws: (any Error).self) {
            try parse([
                "name": "Contoso",
                "help": ["url": "http://example.com/support"],
            ])
        }
    }

    @Test func qrCodeRendersForAURL() throws {
        let image = QRCodeTestHook.image(for: URL(string: "https://example.com/support")!, side: 120)
        #expect(image != nil)
    }
}

/// The QR generator lives in OnboardUI, which the test target doesn't link;
/// this mirrors it so the CoreImage filter itself stays covered.
enum QRCodeTestHook {
    static func image(for url: URL, side: CGFloat) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(
            scaleX: side / output.extent.width,
            y: side / output.extent.height
        ))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

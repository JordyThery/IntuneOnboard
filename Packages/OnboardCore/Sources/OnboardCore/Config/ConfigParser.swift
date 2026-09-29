import Foundation

/// Parses a plist dictionary into a `Configuration`, collecting all errors.
/// Checks that need the whole tree are in `ConfigValidator`.
public enum ConfigParser {
    public static func parse(_ root: [String: Any]) -> (configuration: Configuration?, errors: [ConfigError]) {
        let collector = PlistDecoder.ErrorCollector()
        let decoder = PlistDecoder(dictionary: root, path: "config", errors: collector)

        let schemaVersion = decoder.int("schemaVersion") ?? Configuration.supportedSchemaVersion
        if schemaVersion != Configuration.supportedSchemaVersion {
            collector.add(ConfigError(
                path: "config.schemaVersion",
                kind: .unsupportedSchemaVersion(found: schemaVersion, supported: Configuration.supportedSchemaVersion)
            ))
        }

        let configuration = Configuration(
            schemaVersion: schemaVersion,
            dryRun: decoder.bool("dryRun") ?? false,
            organization: parseOrganization(decoder.child("organization")),
            requireADE: decoder.bool("requireADE") ?? false,
            network: parseNetwork(decoder.child("network")),
            installomator: parseInstallomator(decoder.child("installomator")),
            provisioning: parseProvisioning(decoder.child("provisioning")),
            onboarding: parseOnboarding(decoder.child("onboarding")),
            logging: parseLogging(decoder.child("logging"))
        )

        // Unread keys are reported only when parsing otherwise succeeded;
        // a failed parse leaves keys unread legitimately.
        var errors = collector.errors
        if errors.isEmpty { errors = collector.unknownKeyErrors }
        return (errors.isEmpty ? configuration : nil, errors)
    }

    // MARK: - Sections

    private static func parseOrganization(_ decoder: PlistDecoder?) -> Configuration.Organization? {
        guard let decoder else { return nil }

        var accentColor = decoder.string("accentColor")
        if let value = accentColor, value.wholeMatch(of: /#[0-9A-Fa-f]{6}/) == nil {
            decoder.errors.add(ConfigError(path: "\(decoder.path).accentColor", kind: .invalidAccentColor(value)))
            accentColor = nil
        }

        var supportURL: URL?
        if let raw = decoder.string("supportURL") {
            if let url = URL(string: raw), url.scheme == "https" {
                supportURL = url
            } else {
                decoder.errors.add(ConfigError(path: "\(decoder.path).supportURL", kind: .insecureURL(raw)))
            }
        }

        return Configuration.Organization(
            name: decoder.requiredString("name") ?? "",
            logo: decoder.icon("logo"),
            accentColor: accentColor,
            supportText: decoder.localizedText("supportText"),
            supportURL: supportURL,
            help: parseHelp(decoder.child("help"))
        )
    }

    private static func parseHelp(_ decoder: PlistDecoder?) -> Configuration.Help? {
        guard let decoder else { return nil }

        var url: URL?
        if let raw = decoder.string("url") {
            if let parsed = URL(string: raw), parsed.scheme == "https" {
                url = parsed
            } else {
                decoder.errors.add(ConfigError(path: "\(decoder.path).url", kind: .insecureURL(raw)))
            }
        }

        let help = Configuration.Help(
            title: decoder.localizedText("title"),
            message: decoder.localizedText("message"),
            url: url
        )
        return help.isEmpty ? nil : help
    }

    private static func parseNetwork(_ decoder: PlistDecoder?) -> Configuration.Network {
        guard let decoder else { return Configuration.Network() }
        return Configuration.Network(
            requiredURLs: parseURLList(decoder, key: "requiredURLs"),
            warnURLs: parseURLList(decoder, key: "warnURLs"),
            timeoutSeconds: decoder.int("timeoutSeconds") ?? 30
        )
    }

    private static func parseURLList(_ decoder: PlistDecoder, key: String) -> [URL] {
        guard let strings = decoder.stringArray(key) else { return [] }
        var urls: [URL] = []
        for (index, raw) in strings.enumerated() {
            if let url = URL(string: raw), url.scheme == "https" {
                urls.append(url)
            } else {
                decoder.errors.add(ConfigError(path: "\(decoder.path).\(key)[\(index)]", kind: .insecureURL(raw)))
            }
        }
        return urls
    }

    private static func parseInstallomator(_ decoder: PlistDecoder?) -> Configuration.Installomator {
        guard let decoder else { return Configuration.Installomator() }
        var options = decoder.stringArray("defaultOptions") ?? InstallomatorOptions.bootstrapDefaults
        options = validateOptions(options, decoder: decoder, key: "defaultOptions")
        return Configuration.Installomator(defaultOptions: options)
    }

    private static func validateOptions(_ options: [String], decoder: PlistDecoder, key: String) -> [String] {
        for (index, option) in options.enumerated() {
            if let violation = InstallomatorOptions.violation(of: option) {
                decoder.errors.add(ConfigError(
                    path: "\(decoder.path).\(key)[\(index)]",
                    kind: .invalidOption(option, violation)
                ))
            }
        }
        return options
    }

    private static func parseLogging(_ decoder: PlistDecoder?) -> Configuration.Logging {
        guard let decoder else { return Configuration.Logging() }
        return Configuration.Logging(
            maxFileSizeMB: decoder.int("maxFileSizeMB") ?? 10,
            keepArchives: decoder.int("keepArchives") ?? 3
        )
    }

    // MARK: - Provisioning

    private static func parseProvisioning(_ decoder: PlistDecoder?) -> Configuration.Provisioning? {
        guard let decoder else { return nil }

        // Validated here so a misspelled token rejects the profile.
        var template: NameTemplate?
        if let raw = decoder.string("deviceNameTemplate") {
            do {
                template = try NameTemplate.parse(raw)
            } catch {
                decoder.errors.add(ConfigError(
                    path: "\(decoder.path).deviceNameTemplate",
                    kind: .invalidValue("\(error)")
                ))
            }
        }

        return Configuration.Provisioning(
            title: decoder.localizedText("title"),
            message: decoder.localizedText("message"),
            showDeviceInfo: decoder.bool("showDeviceInfo") ?? true,
            allowContinueOnError: decoder.bool("allowContinueOnError") ?? false,
            deviceNameTemplate: template,
            items: decoder.childArray("items").compactMap(parseProvisioningItem)
        )
    }

    private static func parseProvisioningItem(_ decoder: PlistDecoder) -> ProvisioningItem? {
        guard let id = parseID(decoder) else { return nil }
        guard let kindString = decoder.requiredString("kind") else { return nil }

        let kind: ProvisioningItem.Kind?
        switch kindString {
        case "installomator":
            if let label = decoder.requiredString("label") {
                let options = validateOptions(decoder.stringArray("options") ?? [], decoder: decoder, key: "options")
                kind = .installomator(label: label, options: options)
            } else {
                kind = nil
            }
        case "script":
            kind = parseScript(decoder).map(ProvisioningItem.Kind.script)
        case "wait":
            if let seconds = decoder.int("seconds"), seconds > 0 {
                kind = .wait(seconds: seconds, message: decoder.localizedText("message"))
            } else {
                decoder.errors.add(ConfigError(path: "\(decoder.path).seconds", kind: .invalidValue("wait needs a positive 'seconds'")))
                kind = nil
            }
        case "awaitPath":
            if let path = decoder.requiredString("path") {
                let condition = ProvisioningItem.PathCondition(rawValue: decoder.string("condition") ?? "exists")
                if let condition {
                    kind = .awaitPath(path: path, condition: condition)
                } else {
                    decoder.errors.add(ConfigError(path: "\(decoder.path).condition", kind: .invalidValue("must be 'exists' or 'absent'")))
                    kind = nil
                }
            } else {
                kind = nil
            }
        default:
            decoder.errors.add(ConfigError(path: "\(decoder.path).kind", kind: .unknownKind(kindString)))
            kind = nil
        }

        guard let kind else { return nil }
        return ProvisioningItem(
            id: id,
            kind: kind,
            title: decoder.localizedText("title"),
            subtitle: decoder.localizedText("subtitle"),
            icon: decoder.icon("icon"),
            required: decoder.bool("required") ?? true,
            enabled: decoder.bool("enabled") ?? true,
            timeout: decoder.int("timeout"),
            validatePath: decoder.string("validatePath")
        )
    }

    private static func parseScript(_ decoder: PlistDecoder) -> ProvisioningItem.ScriptSpec? {
        let inline = decoder.string("script")
        let path = decoder.string("path")
        let source: ProvisioningItem.ScriptSpec.Source
        switch (inline, path) {
        case (let inline?, nil):
            source = .inline(inline)
        case (nil, let path?):
            source = .path(path)
        default:
            decoder.errors.add(ConfigError(path: decoder.path, kind: .scriptSourceMissing))
            return nil
        }

        let interpreter = decoder.string("interpreter") ?? "/bin/zsh"
        guard interpreter == "/bin/zsh" || interpreter == "/bin/bash" else {
            decoder.errors.add(ConfigError(path: "\(decoder.path).interpreter", kind: .invalidValue("only /bin/zsh and /bin/bash are allowed")))
            return nil
        }

        return ProvisioningItem.ScriptSpec(
            source: source,
            interpreter: interpreter,
            arguments: decoder.stringArray("arguments") ?? [],
            successExitCodes: decoder.intArray("successExitCodes") ?? [0],
            statusFromOutput: decoder.bool("statusFromOutput") ?? true
        )
    }

    // MARK: - Onboarding

    private static func parseOnboarding(_ decoder: PlistDecoder?) -> Configuration.Onboarding? {
        guard let decoder else { return nil }
        return Configuration.Onboarding(
            title: decoder.localizedText("title"),
            message: decoder.localizedText("message"),
            items: decoder.childArray("items").compactMap(parseOnboardingItem),
            launchOnCompletion: decoder.string("launchOnCompletion").flatMap {
                parseOpenTarget($0, decoder: decoder, key: "launchOnCompletion")
            },
            hideOtherApps: decoder.bool("hideOtherApps") ?? true,
            allowQuit: decoder.bool("allowQuit") ?? true,
            windowPosition: parseWindowPosition(decoder),
            background: decoder.icon("background"),
            blur: decoder.bool("blur") ?? false
        )
    }

    /// Unsupported values are errors rather than falling back to `center`.
    private static func parseWindowPosition(_ decoder: PlistDecoder) -> Configuration.Onboarding.WindowPosition {
        guard let raw = decoder.string("windowPosition") else { return .center }
        guard let position = Configuration.Onboarding.WindowPosition(rawValue: raw) else {
            let supported = Configuration.Onboarding.WindowPosition.allCases
                .map(\.rawValue)
                .joined(separator: ", ")
            decoder.errors.add(ConfigError(
                path: "\(decoder.path).windowPosition",
                kind: .invalidValue("\(raw) — supported: \(supported)")
            ))
            return .center
        }
        return position
    }

    /// An app path, `bundleid:` or URL. Used by `open` and `launchOnCompletion`.
    private static func parseOpenTarget(
        _ raw: String,
        decoder: PlistDecoder,
        key: String
    ) -> OnboardingItem.OpenTarget? {
        if let id = raw.removingPrefix("bundleid:"), !id.isEmpty {
            return .bundleID(id)
        }
        if raw.hasPrefix("/") {
            return .path(raw)
        }
        if let url = URL(string: raw), url.scheme != nil {
            return .url(url)
        }
        decoder.errors.add(ConfigError(
            path: "\(decoder.path).\(key)",
            kind: .invalidValue("must be an app path, bundleid:, or URL")
        ))
        return nil
    }

    private static func parseOnboardingItem(_ decoder: PlistDecoder) -> OnboardingItem? {
        guard let id = parseID(decoder) else { return nil }
        guard let kindString = decoder.requiredString("kind") else { return nil }

        let kind: OnboardingItem.Kind?
        switch kindString {
        case "message":
            kind = .message
        case "wallpaper":
            // A string or an array; an array lets the user choose.
            if !decoder.has("source") {
                decoder.errors.add(ConfigError(path: "\(decoder.path).source", kind: .missingKey))
                kind = nil
            } else if let raws = decoder.strings("source") {
                var sha = decoder.string("sha256")
                if let value = sha, value.wholeMatch(of: /[0-9A-Fa-f]{64}/) == nil {
                    decoder.errors.add(ConfigError(path: "\(decoder.path).sha256", kind: .invalidSHA256(value)))
                    sha = nil
                }
                let sources = raws.compactMap { raw -> OnboardingItem.Source? in
                    if raw.hasPrefix("/") { return .path(raw) }
                    if let url = URL(string: raw), url.scheme == "https" { return .remote(url) }
                    decoder.errors.add(ConfigError(path: "\(decoder.path).source", kind: .insecureURL(raw)))
                    return nil
                }
                if sources.count == raws.count, !sources.isEmpty {
                    kind = .wallpaper(OnboardingItem.WallpaperSpec(
                        sources: sources,
                        sha256: sha,
                        allowKeepExisting: decoder.bool("allowKeepExisting") ?? false
                    ))
                } else {
                    kind = nil
                }
            } else {
                kind = nil
            }
        case "dock":
            // keep, add or replace; a string or an array. Default add.
            var strategies: [OnboardingItem.DockStrategy] = [.add]
            if let raws = decoder.strings("dockStrategy") {
                let parsed = raws.compactMap { OnboardingItem.DockStrategy(rawValue: $0) }
                if parsed.count == raws.count, !parsed.isEmpty {
                    strategies = parsed
                } else {
                    decoder.errors.add(ConfigError(
                        path: "\(decoder.path).dockStrategy",
                        kind: .invalidValue("must be 'keep', 'add' or 'replace' (string or array)")
                    ))
                }
            }
            kind = .dock(OnboardingItem.DockSpec(
                strategies: strategies,
                items: decoder.stringArray("items") ?? [],
                waitForItemsTimeout: decoder.int("waitForItemsTimeout") ?? 0,
                restartDock: decoder.bool("restartDock") ?? true
            ))
        case "defaultApps":
            kind = .defaultApps(OnboardingItem.DefaultAppsSpec(
                browsers: decoder.strings("browser") ?? [],
                urlSchemes: decoder.stringsDict("urlSchemes") ?? [:],
                types: decoder.stringsDict("types") ?? [:],
                allowKeepExisting: decoder.bool("allowKeepExisting") ?? false,
                explanation: decoder.localizedText("explanation")
            ))
        case "open":
            if let raw = decoder.requiredString("target") {
                let target = parseOpenTarget(raw, decoder: decoder, key: "target")
                let completion = OnboardingItem.OpenCompletion(rawValue: decoder.string("completion") ?? "manual")
                if completion == nil {
                    decoder.errors.add(ConfigError(path: "\(decoder.path).completion", kind: .invalidValue("must be 'manual' or 'validatePath'")))
                }
                if let target, let completion {
                    kind = .open(target: target, completion: completion)
                } else {
                    kind = nil
                }
            } else {
                kind = nil
            }
        case "demoteUser":
            kind = .demoteUser(exclude: decoder.stringArray("exclude") ?? [])
        default:
            decoder.errors.add(ConfigError(path: "\(decoder.path).kind", kind: .unknownKind(kindString)))
            kind = nil
        }

        guard let kind else { return nil }

        var mode: OnboardingItem.Mode?
        if let raw = decoder.string("mode") {
            mode = OnboardingItem.Mode(rawValue: raw)
            if mode == nil {
                decoder.errors.add(ConfigError(path: "\(decoder.path).mode", kind: .invalidValue("must be 'automatic' or 'interactive'")))
            }
        }

        return OnboardingItem(
            id: id,
            kind: kind,
            mode: mode,
            title: decoder.localizedText("title"),
            subtitle: decoder.localizedText("subtitle"),
            icon: decoder.icon("icon"),
            buttonTitle: decoder.localizedText("buttonTitle"),
            required: decoder.bool("required") ?? true,
            enabled: decoder.bool("enabled") ?? true,
            timeout: decoder.int("timeout") ?? 600,
            validatePath: decoder.string("validatePath")
        )
    }

    // MARK: - Shared

    private static func parseID(_ decoder: PlistDecoder) -> String? {
        guard let id = decoder.requiredString("id") else { return nil }
        guard id.wholeMatch(of: /[A-Za-z0-9._-]{1,64}/) != nil else {
            decoder.errors.add(ConfigError(path: "\(decoder.path).id", kind: .invalidID(id)))
            return nil
        }
        return id
    }
}

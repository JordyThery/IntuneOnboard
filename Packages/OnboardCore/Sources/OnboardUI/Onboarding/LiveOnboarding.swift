import AppKit
import OnboardCore
import UniformTypeIdentifiers

/// Builds the onboarding view model with live system probes and actions.
@MainActor
public enum LiveOnboarding {
    /// The view model, or nil when the profile has no onboarding items.
    public static func makeViewModel(configuration: Configuration) -> OnboardingViewModel? {
        guard let onboarding = configuration.onboarding, !onboarding.items.isEmpty else {
            return nil
        }

        let engine: OnboardingEngine
        if configuration.dryRun {
            // Dry run: real probes, simulated actions, and a temporary store,
            // so real user state is not changed.
            let world = DryRunOnboardingWorld(base: probes())
            let store = StateStore(rootDirectory: URL(filePath: NSTemporaryDirectory())
                .appending(path: "IntuneOnboard-dryrun-\(UUID().uuidString)"))
            engine = OnboardingEngine(
                items: onboarding.items,
                store: store,
                probes: world.probes,
                actions: DryRunOnboardingActions(world: world)
            )
        } else {
            engine = OnboardingEngine(
                items: onboarding.items,
                probes: probes(),
                actions: OnboardingActionRunner(context: actionContext())
            )
        }
        return OnboardingViewModel(
            engine: engine,
            title: onboarding.title,
            message: onboarding.message,
            accentHex: configuration.organization?.accentColor,
            headerLogo: configuration.organization?.logo,
            launchOnCompletion: onboarding.launchOnCompletion,
            isDryRun: configuration.dryRun
        )
    }

    /// Whether onboarding steps remain, from stored records. Fast and
    /// synchronous, for use before a window exists.
    public static func hasOutstandingWork(configuration: Configuration?) -> Bool {
        guard let items = configuration?.onboarding?.items, !items.isEmpty else {
            return false
        }
        // Dry runs keep no records, so they always have work.
        if configuration?.dryRun == true { return true }
        let state = (try? StateStore.forCurrentUser().loadUserState()) ?? nil
        return state?.completedAt == nil
    }

    // MARK: - Helpers

    /// The bundled helper in Contents/Helpers. Logs an error if it is missing.
    static func helperPath(_ name: String) -> String {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers")
            .appending(path: name)
            .path
        if !FileManager.default.isExecutableFile(atPath: bundled) {
            OnboardLog.app.error("bundled helper missing: \(bundled, privacy: .public) — the step using it will fail")
        }
        return bundled
    }

    // MARK: - Probes

    /// The main display's wallpaper, as reported by desktoppr. Unlike
    /// `NSWorkspace.desktopImageURL(for:)`, it reflects a change made by
    /// another process straight away.
    public static func currentWallpaperPath() async -> String? {
        await probes().currentWallpaperPath()
    }

    static func probes(runner: any ProcessRunning = LiveProcessRunner()) -> OnboardingProbes {
        let desktoppr = helperPath("desktoppr")
        return OnboardingProbes(
            currentUserName: { NSUserName() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            currentWallpaperPath: {
                // One path per screen; the first is the main display.
                let result = try? await runner.run(
                    executable: desktoppr,
                    arguments: [],
                    environment: nil,
                    timeout: .seconds(10),
                    lineHandler: nil
                )
                guard let output = result?.standardOutput, result?.exitCode == 0 else { return nil }
                return output
                    .split(separator: "\n")
                    .first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            },
            currentDefaultApp: { target in
                currentHandler(for: target)
            },
            isMemberOfAdminGroup: { name in
                // Same check as the daemon's demotion.
                let result = try? await runner.run(
                    executable: "/usr/sbin/dseditgroup",
                    arguments: ["-o", "checkmember", "-m", name, "admin"],
                    environment: nil,
                    timeout: .seconds(10),
                    lineHandler: nil
                )
                // Prefix match: "no reyes is NOT a member" contains "yes".
                return result?.standardOutput.hasPrefix("yes") ?? false
            },
            currentDockItems: {
                currentDockApps()
            },
            isAppInstalled: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            }
        )
    }

    /// App paths in the user's Dock, from the Dock's `persistent-apps`.
    private nonisolated static func currentDockApps() -> [String] {
        guard let tiles = UserDefaults(suiteName: "com.apple.dock")?
            .array(forKey: "persistent-apps") as? [[String: Any]]
        else { return [] }
        return tiles.compactMap { tile in
            let fileData = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
            return (fileData?["_CFURLString"] as? String)
                .flatMap(URL.init(string:))?
                .path
        }
    }

    /// The app currently handling a target.
    nonisolated static func currentHandler(for target: DefaultAppTarget) -> String? {
        let url: URL? = switch target {
        case .browser:
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        case .scheme(let scheme):
            URL(string: "\(scheme):probe").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        case .uniformType(let identifier):
            UTType(identifier).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }
        return url.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    // MARK: - Actions

    static func actionContext(runner: any ProcessRunning = LiveProcessRunner()) -> OnboardingActionContext {
        OnboardingActionContext(
            runner: runner,
            desktopprPath: helperPath("desktoppr"),
            dockutilPath: helperPath("dockutil"),
            utilutiPath: helperPath("utiluti"),
            rootService: OnboardServiceClient(),
            applicationPath: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            },
            openTarget: { target in
                await open(target)
            },
            currentDockItems: {
                currentDockApps()
            }
        )
    }

    /// Opens a target and exempts its app from the `focus` backdrop.
    public static func open(_ target: OnboardingItem.OpenTarget) async -> Bool {
        let workspace = NSWorkspace.shared
        do {
            switch target {
            case .path(let path):
                let url = URL(filePath: path)
                FocusExemptions.allow(Bundle(url: url)?.bundleIdentifier)
                try await workspace.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            case .bundleID(let bundleID):
                guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
                    return false
                }
                FocusExemptions.allow(bundleID)
                try await workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            case .url(let url):
                // Any URL scheme, including x-apple.systempreferences:.
                FocusExemptions.allow(
                    workspace.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
                )
                return workspace.open(url)
            }
            return true
        } catch {
            OnboardLog.app.error("open failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

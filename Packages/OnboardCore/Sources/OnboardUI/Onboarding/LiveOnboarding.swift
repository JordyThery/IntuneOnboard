import AppKit
import OnboardCore
import UniformTypeIdentifiers

/// The real-Mac wiring for onboarding: bundled helper paths, system probes and
/// the action context, assembled into a view model. The demo world mirrors
/// this shape in memory; tests use fakes.
@MainActor
public enum LiveOnboarding {
    /// The onboarding view model for the signed-in user, or nil when the
    /// profile configures no onboarding — the caller falls back to the provisioning
    /// summary.
    public static func makeViewModel(configuration: Configuration) -> OnboardingViewModel? {
        guard let onboarding = configuration.onboarding, !onboarding.items.isEmpty else {
            return nil
        }

        let engine: OnboardingEngine
        if configuration.dryRun {
            // The profile's DEBUG dry run: real probes behind an in-memory
            // overlay, simulated actions, and records in a throwaway store —
            // the real user state (and its completion marker) stays untouched,
            // so the onboarding re-offers itself on every launch until the key
            // is removed.
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

    /// Does this user still have onboarding work? Record-based on purpose: it
    /// is consulted before any window exists, so it must be cheap and
    /// synchronous. The fine-grained answer (statuses re-derived from the
    /// system) belongs to the engine once the window is up.
    public static func hasOutstandingWork(configuration: Configuration?) -> Bool {
        guard let items = configuration?.onboarding?.items, !items.isEmpty else {
            return false
        }
        // A DEBUG dry run always has work: its records live in a throwaway
        // store, and a marker earned by an earlier *real* run must not
        // silence it.
        if configuration?.dryRun == true { return true }
        let state = (try? StateStore.forCurrentUser().loadUserState()) ?? nil
        return state?.completedAt == nil
    }

    // MARK: - Helpers

    /// The bundled helper (Contents/Helpers, signed with the app) — and only
    /// that. This used to fall back to `/usr/local/bin`, which Homebrew
    /// routinely leaves writable by the console user: no privilege crossed
    /// (the helpers run as that same user), but it executed an unpinned,
    /// unsigned binary and silently papered over a broken bundle. A missing
    /// helper now fails the step it belongs to, loudly, with a path that
    /// names the actual problem.
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

    static func probes(runner: any ProcessRunning = LiveProcessRunner()) -> OnboardingProbes {
        let desktoppr = helperPath("desktoppr")
        return OnboardingProbes(
            currentUserName: { NSUserName() },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            currentWallpaperPath: {
                // desktoppr with no arguments prints the current wallpaper,
                // one path per screen; the first is the main display.
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
                // The same question the demote action's daemon side asks, so
                // derivation and action can never disagree about membership.
                let result = try? await runner.run(
                    executable: "/usr/sbin/dseditgroup",
                    arguments: ["-o", "checkmember", "-m", name, "admin"],
                    environment: nil,
                    timeout: .seconds(10),
                    lineHandler: nil
                )
                // Prefix, not contains — "no reyes is NOT a member" contains
                // "yes". Same parsing as the daemon's demote check.
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

    /// The user's Dock as it is now: `persistent-apps` from the Dock's own
    /// preferences, each tile a file:// URL. Read directly rather than via
    /// dockutil --list — no subprocess, and the preview refreshes instantly.
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

    /// Launch Services' answer for who currently handles a target. Not
    /// main-actor work: the probes call it from wherever derivation runs.
    /// Not private: the defaultApps step shows the current handler as a tile,
    /// and it must be the same answer derivation measures against.
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

    /// Public because Done's launchOnCompletion uses it from the app too.
    ///
    /// Whatever gets launched is also marked exempt from the focus backdrop:
    /// an app onboarding itself sent the user to has to be usable, and
    /// nothing else does.
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
                // Any scheme, deliberately — x-apple.systempreferences: deep
                // links are the point. Exempt whichever app will handle it.
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

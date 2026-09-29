import Foundation

/// The two operations onboarding cannot do as the user: putting a downloaded
/// wallpaper into root-owned `/Library`, and editing the admin group. The
/// daemon implements this over XPC; tests and the demo use fakes.
///
/// Deliberately narrow: the caller passes item ids and indexes, never URLs or
/// usernames — the daemon resolves both from its *own* config and console
/// user, so a compromised caller cannot fetch arbitrary URLs as root or
/// demote arbitrary accounts.
public protocol OnboardingRootServicing: Sendable {
    /// Ensures the item's source `sourceIndex` exists at its shared local
    /// destination; returns that path.
    func fetchWallpaper(itemID: String, sourceIndex: Int) async throws -> String
    /// Removes the console user from the admin group, honouring the item's
    /// exclude list. Returns false when no demotion was needed.
    func demoteConsoleUser(itemID: String) async throws -> Bool
}

/// Everything the onboarding actions need, injectable for tests — the onboarding
/// counterpart of `ActionContext`.
public struct OnboardingActionContext: Sendable {
    public var runner: any ProcessRunning
    /// Bundled helper binaries (Contents/Helpers in the app).
    public var desktopprPath: String
    public var dockutilPath: String
    public var utilutiPath: String
    public var rootService: any OnboardingRootServicing
    public var fileExists: @Sendable (String) -> Bool
    /// App path for a bundle id (Launch Services in the live wiring).
    public var applicationPath: @Sendable (String) -> String?
    /// Launches an open-step target; true when launch succeeded.
    public var openTarget: @Sendable (OnboardingItem.OpenTarget) async -> Bool
    /// App paths already in this user's Dock. The `add` action consults it
    /// first: dockutil exits non-zero on a duplicate, and an app the user
    /// already has is the desired end state, not a failure.
    public var currentDockItems: @Sendable () async -> [String]
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        runner: any ProcessRunning = LiveProcessRunner(),
        desktopprPath: String,
        dockutilPath: String,
        utilutiPath: String,
        rootService: any OnboardingRootServicing,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        applicationPath: @escaping @Sendable (String) -> String? = { _ in nil },
        openTarget: @escaping @Sendable (OnboardingItem.OpenTarget) async -> Bool,
        currentDockItems: @escaping @Sendable () async -> [String] = { [] },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.desktopprPath = desktopprPath
        self.dockutilPath = dockutilPath
        self.utilutiPath = utilutiPath
        self.rootService = rootService
        self.fileExists = fileExists
        self.applicationPath = applicationPath
        self.openTarget = openTarget
        self.currentDockItems = currentDockItems
        self.sleep = sleep
    }
}

/// The five kinds, behaving per Docs/Onboarding-Behaviour.md. Runs as the
/// signed-in user; only the root protocol leaves the process.
public struct OnboardingActionRunner: OnboardingActing {
    private let context: OnboardingActionContext

    public init(context: OnboardingActionContext) {
        self.context = context
    }

    public func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord {
        if case .keepCurrent = choice {
            return ItemRecord(outcome: .skipped, status: .notNeeded)
        }
        switch item.kind {
        case .message:
            // Nothing to do: seeing the step is the step.
            return ItemRecord(outcome: .success, status: .done)
        case .wallpaper(let spec):
            return await wallpaper(item: item, spec: spec, choice: choice)
        case .dock(let spec):
            return await dock(spec: spec, choice: choice)
        case .defaultApps(let spec):
            return await defaultApps(spec: spec, choice: choice)
        case .open(let target, _):
            let opened = await context.openTarget(target)
            return opened
                ? ItemRecord(outcome: .success, status: .awaitingUser)
                : ItemRecord(outcome: .failed, status: .failed, message: "could not open the target")
        case .demoteUser:
            return await demote(item: item)
        }
    }

    // MARK: - wallpaper

    private func wallpaper(
        item: OnboardingItem,
        spec: OnboardingItem.WallpaperSpec,
        choice: StepChoice?
    ) async -> ItemRecord {
        let index: Int
        if case .wallpaper(let chosen) = choice {
            index = chosen
        } else if spec.sources.count == 1 {
            index = 0
        } else {
            return ItemRecord(outcome: .failed, status: .failed, message: "no wallpaper chosen")
        }
        guard spec.sources.indices.contains(index) else {
            return ItemRecord(outcome: .failed, status: .failed, message: "wallpaper choice out of range")
        }

        let source = spec.sources[index]
        let destination = WallpaperLocation.destination(for: source).path

        switch source {
        case .path:
            // An absent local file is a skip, not a failure: "no wallpaper
            // configured locally" is a normal state (behaviour spec).
            guard context.fileExists(destination) else {
                return ItemRecord(outcome: .skipped, status: .notNeeded, message: "wallpaper file not present")
            }
        case .remote:
            // The daemon downloads (or has pre-fetched) into the shared
            // location. A failed download is a real failure — it was asked
            // for and didn't happen.
            if !context.fileExists(destination) {
                do {
                    _ = try await context.rootService.fetchWallpaper(itemID: item.id, sourceIndex: index)
                } catch {
                    return ItemRecord(outcome: .failed, status: .downloadFailed, message: error.localizedDescription)
                }
            }
        }

        do {
            let result = try await context.runner.run(
                executable: context.desktopprPath,
                arguments: [destination],
                environment: nil,
                timeout: .seconds(30),
                lineHandler: nil
            )
            guard result.exitCode == 0 else {
                return ItemRecord(outcome: .failed, status: .failed, message: "desktoppr exited \(result.exitCode)")
            }
            return ItemRecord(outcome: .success, status: .done)
        } catch {
            return ItemRecord(outcome: .failed, status: .failed, message: error.localizedDescription)
        }
    }

    // MARK: - dock

    private func dock(spec: OnboardingItem.DockSpec, choice: StepChoice?) async -> ItemRecord {
        let action: OnboardingItem.DockStrategy
        if case .dock(let chosen) = choice, spec.strategies.contains(chosen) {
            action = chosen
        } else {
            action = spec.strategies.first ?? .add
        }
        if action == .keep {
            return ItemRecord(outcome: .skipped, status: .notNeeded)
        }

        // Give provisioning time to finish installing apps the Dock lists.
        if spec.waitForItemsTimeout > 0 {
            let deadline = Date.now.addingTimeInterval(TimeInterval(spec.waitForItemsTimeout))
            while Date.now < deadline, !spec.items.allSatisfy(itemPresent) {
                await context.sleep(.seconds(2))
            }
        }

        var problems: [String] = []
        if action == .replace, await dockutil(["--remove", "all", "--no-restart"]) != 0 {
            problems.append("could not empty the Dock")
        }

        // Read the Dock after any --remove, so `replace` sees the empty one it
        // just made and re-adds everything.
        let present = Set(await context.currentDockItems())

        // Missing items are skipped, not failed — it is what prevents
        // question-mark Dock icons and makes listing not-everywhere apps safe.
        //
        // So is an item the user already has. dockutil exits non-zero rather
        // than duplicate an entry, and counting that as a failure marked the
        // whole step failed for a Dock that ended up exactly as configured —
        // which is what listing a default app like Apps.app or System
        // Settings did on hardware.
        var added = 0, skipped = 0
        for item in spec.items {
            guard let path = resolvedDockPath(item) else {
                skipped += 1
                continue
            }
            guard !present.contains(path) else {
                added += 1
                continue
            }
            if await dockutil(["--add", path, "--no-restart"]) == 0 {
                added += 1
            } else {
                problems.append("could not add \(path)")
            }
        }

        // One restart after all edits, and only this user's Dock — which is
        // what `killall` scoped to our own uid does.
        if spec.restartDock {
            _ = try? await context.runner.run(
                executable: "/usr/bin/killall",
                arguments: ["Dock"],
                environment: nil,
                timeout: .seconds(10),
                lineHandler: nil
            )
        }

        // The message names what actually went wrong. It used to repeat the
        // counts, which read as a failure report on a Dock that was fine.
        let detail = ["added": added, "skipped": skipped]
        return problems.isEmpty
            ? ItemRecord(outcome: .success, status: .done, detail: detail)
            : ItemRecord(outcome: .failed, status: .failed, detail: detail, message: problems.joined(separator: "; "))
    }

    private func itemPresent(_ item: String) -> Bool {
        resolvedDockPath(item) != nil
    }

    /// `bundleid:` entries resolve through the item icon convention; plain
    /// entries are paths. nil = not on this Mac (→ skipped).
    private func resolvedDockPath(_ item: String) -> String? {
        if item.hasPrefix("bundleid:") {
            let bundleID = String(item.dropFirst("bundleid:".count))
            return context.applicationPath(bundleID)
        }
        return context.fileExists(item) ? item : nil
    }

    private func dockutil(_ arguments: [String]) async -> Int32 {
        (try? await context.runner.run(
            executable: context.dockutilPath,
            arguments: arguments,
            environment: nil,
            timeout: .seconds(30),
            lineHandler: nil
        ))?.exitCode ?? -1
    }

    // MARK: - defaultApps

    private func defaultApps(spec: OnboardingItem.DefaultAppsSpec, choice: StepChoice?) async -> ItemRecord {
        // Targets whose candidates are all absent from this Mac are skipped,
        // not failed — an absent app can't be chosen, and failing the step
        // over it would punish the user for the deployment's timing. The same
        // skip-missing philosophy as the dock items. Installed = Launch
        // Services knows a path for the bundle id.
        let actionable = spec.targets.filter { _, candidates in
            candidates.contains { context.applicationPath($0) != nil }
        }
        guard !actionable.isEmpty else {
            return ItemRecord(outcome: .skipped, status: .notNeeded, message: "none of the configured apps are installed")
        }

        // The UI sends every target's pick; scalar confirmations seed sole
        // *installed* candidates. Anything unpicked here is a config/UI
        // inconsistency.
        var picks: [String: String] = [:]
        if case .defaultApps(let chosen) = choice { picks = chosen }
        for (target, candidates) in actionable where picks[target.key] == nil {
            let installed = candidates.filter { context.applicationPath($0) != nil }
            guard installed.count == 1 else {
                return ItemRecord(outcome: .failed, status: .failed, message: "no choice made for \(target.key)")
            }
            picks[target.key] = installed[0]
        }

        for (target, _) in actionable {
            guard let bundleID = picks[target.key] else { continue }
            // utiluti's real subcommands, from the vendored binary's help
            // after hardware returned EX_USAGE (64) on the guessed spelling:
            //   utiluti url set <scheme> <bundleID>
            //   utiluti type set <identifier> <bundleID>
            // The browser is the http scheme.
            let arguments: [String] = switch target {
            case .browser: ["url", "set", "http", bundleID]
            case .scheme(let scheme): ["url", "set", scheme, bundleID]
            case .uniformType(let uti): ["type", "set", uti, bundleID]
            }
            do {
                let result = try await context.runner.run(
                    executable: context.utilutiPath,
                    arguments: arguments,
                    environment: nil,
                    timeout: .seconds(60),
                    lineHandler: nil
                )
                guard result.exitCode == 0 else {
                    // Includes the user refusing macOS's confirmation prompt:
                    // retryable, and the message says which target.
                    return ItemRecord(
                        outcome: .failed,
                        status: .awaitingUser,
                        message: "\(target.key) was not changed (utiluti exited \(result.exitCode))"
                    )
                }
            } catch {
                return ItemRecord(outcome: .failed, status: .failed, message: error.localizedDescription)
            }
        }
        return ItemRecord(outcome: .success, status: .done)
    }

    // MARK: - demoteUser

    private func demote(item: OnboardingItem) async -> ItemRecord {
        do {
            let demoted = try await context.rootService.demoteConsoleUser(itemID: item.id)
            return demoted
                ? ItemRecord(outcome: .success, status: .done)
                : ItemRecord(outcome: .skipped, status: .notNeeded)
        } catch {
            return ItemRecord(outcome: .failed, status: .failed, message: error.localizedDescription)
        }
    }
}

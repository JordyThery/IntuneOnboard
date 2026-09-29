import Foundation

/// The two onboarding operations that need root, performed by the daemon:
/// storing a downloaded wallpaper and removing admin membership. Callers pass
/// only an item id and index; the daemon resolves the URL and user itself.
public protocol OnboardingRootServicing: Sendable {
    /// Makes the item's source available locally; returns its path.
    func fetchWallpaper(itemID: String, sourceIndex: Int) async throws -> String
    /// Removes the console user from the admin group unless excluded.
    /// Returns false when no change was needed.
    func demoteConsoleUser(itemID: String) async throws -> Bool
}

/// Dependencies for onboarding actions; injectable for tests.
public struct OnboardingActionContext: Sendable {
    public var runner: any ProcessRunning
    /// Bundled tools in Contents/Helpers.
    public var desktopprPath: String
    public var dockutilPath: String
    public var utilutiPath: String
    public var rootService: any OnboardingRootServicing
    public var fileExists: @Sendable (String) -> Bool
    /// App path for a bundle id.
    public var applicationPath: @Sendable (String) -> String?
    /// Opens an `open` target; true on success.
    public var openTarget: @Sendable (OnboardingItem.OpenTarget) async -> Bool
    /// App paths in the user's Dock; items already present are not added again.
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

/// Performs onboarding steps as the signed-in user. See
/// Docs/Onboarding-Behaviour.md.
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
            // A missing local file is skipped.
            guard context.fileExists(destination) else {
                return ItemRecord(outcome: .skipped, status: .notNeeded, message: "wallpaper file not present")
            }
        case .remote:
            // Downloaded by the daemon; a failed download fails the step.
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

        // Wait for listed apps that provisioning is still installing.
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

        // Read after any removal, so `replace` adds every item back.
        let present = Set(await context.currentDockItems())

        // Skip items that are not installed or are already in the Dock;
        // dockutil fails on duplicates.
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

        // One restart, after all changes. `killall` affects only this user's Dock.
        if spec.restartDock {
            _ = try? await context.runner.run(
                executable: "/usr/bin/killall",
                arguments: ["Dock"],
                environment: nil,
                timeout: .seconds(10),
                lineHandler: nil
            )
        }

        let detail = ["added": added, "skipped": skipped]
        return problems.isEmpty
            ? ItemRecord(outcome: .success, status: .done, detail: detail)
            : ItemRecord(outcome: .failed, status: .failed, detail: detail, message: problems.joined(separator: "; "))
    }

    private func itemPresent(_ item: String) -> Bool {
        resolvedDockPath(item) != nil
    }

    /// The item's path, resolving `bundleid:` entries; nil if not installed.
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
        // Skip targets with no installed candidate.
        let actionable = spec.targets.filter { _, candidates in
            candidates.contains { context.applicationPath($0) != nil }
        }
        guard !actionable.isEmpty else {
            return ItemRecord(outcome: .skipped, status: .notNeeded, message: "none of the configured apps are installed")
        }

        // Single installed candidates need no choice from the UI.
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
            //   utiluti url set <scheme> <bundleID>    (browser: http)
            //   utiluti type set <uti> <bundleID>
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
                    // Includes the user declining the macOS prompt; retryable.
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

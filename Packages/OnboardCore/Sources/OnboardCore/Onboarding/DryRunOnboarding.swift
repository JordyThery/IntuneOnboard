import Foundation

/// Onboarding for a `dryRun` profile: steps are evaluated against the Mac's
/// real state, but changes are kept in an in-memory overlay and never applied.
public final class DryRunOnboardingWorld: @unchecked Sendable {
    private let lock = NSLock()
    private let base: OnboardingProbes

    // Values changed by the dry run; nil means use the real value.
    private var wallpaper: String?
    private var defaults: [String: String] = [:]
    private var demotedUsers: Set<String> = []
    private var touchedFiles: Set<String> = []

    public init(base: OnboardingProbes) {
        self.base = base
    }

    /// The real probes, with the overlay taking precedence.
    public var probes: OnboardingProbes {
        OnboardingProbes(
            currentUserName: base.currentUserName,
            fileExists: { [self] path in
                lock.withLock { touchedFiles.contains(path) } || base.fileExists(path)
            },
            currentWallpaperPath: { [self] in
                if let overlaid = lock.withLock({ wallpaper }) { return overlaid }
                return await base.currentWallpaperPath()
            },
            currentDefaultApp: { [self] target in
                if let overlaid = lock.withLock({ defaults[target.key] }) { return overlaid }
                return await base.currentDefaultApp(target)
            },
            isMemberOfAdminGroup: { [self] name in
                if lock.withLock({ demotedUsers.contains(name) }) { return false }
                return await base.isMemberOfAdminGroup(name)
            },
            currentDockItems: base.currentDockItems,
            isAppInstalled: base.isAppInstalled
        )
    }

    fileprivate func setWallpaper(_ path: String) { lock.withLock { wallpaper = path } }
    fileprivate func setDefault(_ key: String, to bundleID: String) { lock.withLock { defaults[key] = bundleID } }
    fileprivate func demote(_ name: String) { lock.withLock { _ = demotedUsers.insert(name) } }
    fileprivate func touch(_ path: String) { lock.withLock { _ = touchedFiles.insert(path) } }
}

/// The real actions' decision logic, applied to the overlay. Runs no
/// processes, XPC calls or apps.
public struct DryRunOnboardingActions: OnboardingActing {
    private let world: DryRunOnboardingWorld
    private let sleep: @Sendable (Duration) async -> Void

    public init(
        world: DryRunOnboardingWorld,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.world = world
        self.sleep = sleep
    }

    public func perform(_ item: OnboardingItem, choice: StepChoice?) async -> ItemRecord {
        // Brief pause, so the running state is visible.
        await sleep(.milliseconds(700))

        if case .keepCurrent = choice {
            return ItemRecord(outcome: .skipped, status: .notNeeded)
        }
        let probes = world.probes

        switch item.kind {
        case .message:
            return ItemRecord(outcome: .success, status: .done)

        case .wallpaper(let spec):
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
            if case .path = source, !probes.fileExists(destination) {
                return ItemRecord(outcome: .skipped, status: .notNeeded, message: "wallpaper file not present")
            }
            // Downloads are assumed to succeed.
            world.touch(destination)
            world.setWallpaper(destination)
            return ItemRecord(outcome: .success, status: .done, message: "dry run — simulated")

        case .dock(let spec):
            let action: OnboardingItem.DockStrategy
            if case .dock(let chosen) = choice, spec.strategies.contains(chosen) {
                action = chosen
            } else {
                action = spec.strategies.first ?? .add
            }
            if action == .keep {
                return ItemRecord(outcome: .skipped, status: .notNeeded)
            }
            // Same skipped count as the real action.
            var added = 0, skipped = 0
            for entry in spec.items {
                if entry.hasPrefix("bundleid:") {
                    let bundleID = String(entry.dropFirst("bundleid:".count))
                    probes.isAppInstalled(bundleID) ? (added += 1) : (skipped += 1)
                } else {
                    probes.fileExists(entry) ? (added += 1) : (skipped += 1)
                }
            }
            return ItemRecord(
                outcome: .success,
                status: .done,
                detail: ["added": added, "skipped": skipped],
                message: "dry run — simulated"
            )

        case .defaultApps(let spec):
            let actionable = spec.targets.filter { _, candidates in
                candidates.contains(where: probes.isAppInstalled)
            }
            guard !actionable.isEmpty else {
                return ItemRecord(outcome: .skipped, status: .notNeeded, message: "none of the configured apps are installed")
            }
            var picks: [String: String] = [:]
            if case .defaultApps(let chosen) = choice { picks = chosen }
            for (target, candidates) in actionable where picks[target.key] == nil {
                let installed = candidates.filter(probes.isAppInstalled)
                guard installed.count == 1 else {
                    return ItemRecord(outcome: .failed, status: .failed, message: "no choice made for \(target.key)")
                }
                picks[target.key] = installed[0]
            }
            // Assumes the user accepts the macOS prompt.
            for (target, _) in actionable {
                if let bundleID = picks[target.key] {
                    world.setDefault(target.key, to: bundleID)
                }
            }
            return ItemRecord(outcome: .success, status: .done, message: "dry run — simulated")

        case .open:
            // Opens nothing.
            if let path = item.validatePath {
                world.touch(path)
            }
            return ItemRecord(outcome: .success, status: .awaitingUser, message: "dry run — not opened")

        case .demoteUser(let exclude):
            let user = probes.currentUserName()
            if exclude.contains(user) {
                return ItemRecord(outcome: .skipped, status: .notNeeded)
            }
            guard await probes.isMemberOfAdminGroup(user) else {
                return ItemRecord(outcome: .skipped, status: .notNeeded)
            }
            world.demote(user)
            return ItemRecord(outcome: .success, status: .done, message: "dry run — simulated")
        }
    }
}

import CryptoKit
import Foundation

/// An onboarding step's standing: **re-derived from the system every time
/// the list loads**, not just read back from stored state. A step the user
/// undoes in System Settings un-completes; a step whose end state already
/// holds (the browser is already Edge) completes without ever running.
public enum StepStatus: Equatable, Sendable {
    /// Needs doing — shown in the sidebar's suggested queue.
    case suggested
    /// Satisfied during this session; Continue is enabled and pressing it
    /// acknowledges the step. Only the engine produces this — derivation
    /// yields suggested/completed, because "satisfied but unacknowledged"
    /// is a session-level distinction, not a system state.
    case canContinue
    /// Done — filtered from the suggested queue but still reachable.
    case completed
}

/// The user's pick on a step whose config offered choices (array-shaped
/// values). Scalar-shaped steps pass `nil` or `.keepCurrent`.
public enum StepChoice: Equatable, Sendable {
    /// "Leave it as it is" — offered when the step's `allowKeepExisting` is true.
    case keepCurrent
    /// Index into `WallpaperSpec.sources`.
    case wallpaper(sourceIndex: Int)
    case dock(OnboardingItem.DockStrategy)
    /// Target key (`http`, a scheme, or a UTI) → chosen bundle id.
    case defaultApps([String: String])
}

/// What derivation is allowed to ask the system. Injected so the rules stay
/// pure and testable; the live implementations arrive with the actions.
public struct OnboardingProbes: Sendable {
    /// The console user the onboarding runs for.
    public var currentUserName: @Sendable () -> String
    public var fileExists: @Sendable (String) -> Bool
    /// desktoppr with no arguments prints the current wallpaper's path.
    public var currentWallpaperPath: @Sendable () async -> String?
    /// Current handler for a target. Keys as in `StepChoice.defaultApps`.
    public var currentDefaultApp: @Sendable (DefaultAppTarget) async -> String?
    public var isMemberOfAdminGroup: @Sendable (String) async -> Bool
    /// App paths currently in the user's Dock (persistent-apps), in order —
    /// what the dock step's preview simulates its actions against.
    public var currentDockItems: @Sendable () async -> [String]
    /// Whether an app with this bundle id is installed. Drives the
    /// auto-skip: a defaultApps candidate that isn't on the Mac can't be
    /// picked and must not block the step. Defaults to "assume installed" —
    /// the safe direction, since assuming *missing* would silently auto-skip
    /// everything in a wiring that forgot the probe.
    public var isAppInstalled: @Sendable (String) -> Bool

    public init(
        currentUserName: @escaping @Sendable () -> String,
        fileExists: @escaping @Sendable (String) -> Bool,
        currentWallpaperPath: @escaping @Sendable () async -> String?,
        currentDefaultApp: @escaping @Sendable (DefaultAppTarget) async -> String?,
        isMemberOfAdminGroup: @escaping @Sendable (String) async -> Bool,
        currentDockItems: @escaping @Sendable () async -> [String] = { [] },
        isAppInstalled: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.currentUserName = currentUserName
        self.fileExists = fileExists
        self.currentWallpaperPath = currentWallpaperPath
        self.currentDefaultApp = currentDefaultApp
        self.isMemberOfAdminGroup = isMemberOfAdminGroup
        self.currentDockItems = currentDockItems
        self.isAppInstalled = isAppInstalled
    }
}

/// What the Dock would contain after each action — the preview is computed
/// from the *current* Dock, not just the configured list, because "replace"
/// only means something against what is there now. Pure, so the merge
/// is testable; nothing is applied here.
public enum DockPreview {
    /// - Parameters:
    ///   - current: the user's Dock now, in order.
    ///   - recommended: the configured items, already resolved to existing
    ///     paths (missing apps are skipped from the preview exactly as the
    ///     action would skip them).
    public static func items(
        current: [String],
        recommended: [String],
        action: OnboardingItem.DockStrategy
    ) -> [String] {
        switch action {
        case .keep:
            return current
        case .replace:
            return recommended
        case .add:
            // dockutil refuses duplicates, so the preview must too.
            let present = Set(current)
            return current + recommended.filter { !present.contains($0) }
        }
    }
}

/// One target a defaultApps step manages.
public enum DefaultAppTarget: Hashable, Sendable {
    case browser
    case scheme(String)
    case uniformType(String)

    /// The key used in `StepChoice.defaultApps` and in records.
    public var key: String {
        switch self {
        case .browser: "http"
        case .scheme(let scheme): scheme
        case .uniformType(let uti): uti
        }
    }
}

extension OnboardingItem.DefaultAppsSpec {
    /// Every target this step manages, with its candidates, in a stable order.
    public var targets: [(target: DefaultAppTarget, candidates: [String])] {
        var result: [(DefaultAppTarget, [String])] = []
        if !browsers.isEmpty { result.append((.browser, browsers)) }
        for scheme in urlSchemes.keys.sorted() {
            result.append((.scheme(scheme), urlSchemes[scheme] ?? []))
        }
        for uti in types.keys.sorted() {
            result.append((.uniformType(uti), types[uti] ?? []))
        }
        return result
    }
}

/// Where a wallpaper source lives locally once available.
public enum WallpaperLocation {
    /// Shared, root-owned; the daemon downloads here so every user's onboarding
    /// finds the file without its own network round trip.
    public static let sharedDirectory = URL(
        filePath: "/Library/Application Support/IntuneOnboard/wallpaper"
    )

    /// Local path for a source. Remote files are named by a URL-hash prefix +
    /// basename, so two sources ending in `wallpaper.jpg` cannot collide.
    public static func destination(
        for source: OnboardingItem.Source,
        in directory: URL = sharedDirectory
    ) -> URL {
        switch source {
        case .path(let path):
            return URL(filePath: path)
        case .remote(let url):
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
            return directory.appending(path: "\(prefix)-\(url.lastPathComponent)")
        }
    }
}

/// The re-derivation rules, one per kind. Pure given the probes.
public enum OnboardingDerivation {
    public static func status(
        of item: OnboardingItem,
        record: ItemRecord?,
        probes: OnboardingProbes
    ) async -> StepStatus {
        // Disabled items are recorded as skipped and never suggested.
        guard item.enabled else { return .completed }

        switch item.kind {
        case .message:
            // Completes the moment it has been seen — the auto-perform on
            // selection writes the record; there is nothing to measure.
            return recordBased(record)

        case .wallpaper(let spec):
            // Completed when the wallpaper on screen *is* one of ours —
            // desktoppr can read it back, so this survives the user changing
            // it in System Settings (it un-completes) and survives a wiped
            // state file (it stays completed).
            if record?.outcome == .skipped { return .completed }
            guard let current = await probes.currentWallpaperPath() else {
                return recordBased(record)
            }
            let ours = spec.sources.map { WallpaperLocation.destination(for: $0).path }
            return ours.contains(current) ? .completed : .suggested

        case .dock:
            // No cheap way to read "is the Dock as configured" back, so the
            // record decides.
            return recordBased(record)

        case .defaultApps(let spec):
            // Auto-completes when every managed target is already set to one
            // of its candidates — prompting for something already true is
            // just noise with a confirmation dialog attached.
            for (target, candidates) in spec.targets {
                // A target none of whose candidates are installed is
                // auto-skipped: it can't be acted on, so it must not hold
                // the step hostage.
                guard candidates.contains(where: probes.isAppInstalled) else {
                    continue
                }
                guard let current = await probes.currentDefaultApp(target),
                      candidates.contains(current)
                else {
                    // Completion is MEASURED, never taken from a success
                    // record: utiluti exiting 0 only means the request was
                    // made — the user can still decline macOS's own prompt,
                    // and hardware showed exactly that gap. The one recorded
                    // outcome that counts is "keep current" (skipped), which
                    // is a decision, not a claim about the system.
                    return record?.outcome == .skipped ? .completed : .suggested
                }
            }
            return .completed

        case .open(_, let completion):
            switch completion {
            case .validatePath:
                if let path = item.validatePath, probes.fileExists(path) {
                    return .completed
                }
                return .suggested
            case .manual:
                return recordBased(record)
            }

        case .demoteUser(let exclude):
            let user = probes.currentUserName()
            if exclude.contains(user) { return .completed }
            // Membership is the truth, whatever any record says: demotion by
            // other means completes it, re-promotion un-completes it.
            return await probes.isMemberOfAdminGroup(user) ? .suggested : .completed
        }
    }

    private static func recordBased(_ record: ItemRecord?) -> StepStatus {
        switch record?.outcome {
        case .success, .skipped: .completed
        default: .suggested
        }
    }
}

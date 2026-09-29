import CryptoKit
import Foundation

/// A step's status, evaluated from the system each time, not taken from
/// stored state. Reverting a setting makes the step incomplete again.
public enum StepStatus: Equatable, Sendable {
    /// Not done.
    case suggested
    /// Done in this session; Continue acknowledges it. Set by the engine,
    /// never by derivation.
    case canContinue
    /// Done.
    case completed
}

/// The user's selection for a step that offers a choice.
public enum StepChoice: Equatable, Sendable {
    /// Keep the current setting (`allowKeepExisting`).
    case keepCurrent
    /// Index into `WallpaperSpec.sources`.
    case wallpaper(sourceIndex: Int)
    case dock(OnboardingItem.DockStrategy)
    /// Target key (`http`, a scheme or a UTI) to bundle id.
    case defaultApps([String: String])
}

/// System queries used by derivation; injectable for tests.
public struct OnboardingProbes: Sendable {
    /// The user onboarding runs for.
    public var currentUserName: @Sendable () -> String
    public var fileExists: @Sendable (String) -> Bool
    /// The current wallpaper, from desktoppr.
    public var currentWallpaperPath: @Sendable () async -> String?
    /// The current handler for a target.
    public var currentDefaultApp: @Sendable (DefaultAppTarget) async -> String?
    public var isMemberOfAdminGroup: @Sendable (String) async -> Bool
    /// App paths in the user's Dock, in order.
    public var currentDockItems: @Sendable () async -> [String]
    /// Whether an app is installed. Defaults to true, so a missing probe
    /// never skips steps.
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

/// The Dock after each strategy, computed from the current Dock.
public enum DockPreview {
    /// - Parameters:
    ///   - current: the current Dock, in order.
    ///   - recommended: configured items that exist on this Mac.
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
            // No duplicates, as with dockutil.
            let present = Set(current)
            return current + recommended.filter { !present.contains($0) }
        }
    }
}

/// One target of a `defaultApps` step.
public enum DefaultAppTarget: Hashable, Sendable {
    case browser
    case scheme(String)
    case uniformType(String)

    /// Key used in `StepChoice.defaultApps` and in records.
    public var key: String {
        switch self {
        case .browser: "http"
        case .scheme(let scheme): scheme
        case .uniformType(let uti): uti
        }
    }
}

extension OnboardingItem.DefaultAppsSpec {
    /// Targets with their candidates, in a stable order.
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

/// Local locations of wallpaper sources.
public enum WallpaperLocation {
    /// Root-owned directory the daemon downloads into, shared by all users.
    public static let sharedDirectory = URL(
        filePath: "/Library/Application Support/IntuneOnboard/wallpaper"
    )

    /// Local path for a source. Downloads are named by URL hash prefix and
    /// file name, so names cannot collide.
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

/// Status rules per kind.
public enum OnboardingDerivation {
    public static func status(
        of item: OnboardingItem,
        record: ItemRecord?,
        probes: OnboardingProbes
    ) async -> StepStatus {
        // Disabled items count as done.
        guard item.enabled else { return .completed }

        switch item.kind {
        case .message:
            // Completed by being viewed.
            return recordBased(record)

        case .wallpaper(let spec):
            // Done when the current wallpaper is one of the sources.
            if record?.outcome == .skipped { return .completed }
            guard let current = await probes.currentWallpaperPath() else {
                return recordBased(record)
            }
            let ours = spec.sources.map { WallpaperLocation.destination(for: $0).path }
            return ours.contains(current) ? .completed : .suggested

        case .dock:
            // Not measurable; uses the record.
            return recordBased(record)

        case .defaultApps(let spec):
            // Done when every target already uses one of its candidates.
            for (target, candidates) in spec.targets {
                // Skip targets with no installed candidate.
                guard candidates.contains(where: probes.isAppInstalled) else {
                    continue
                }
                guard let current = await probes.currentDefaultApp(target),
                      candidates.contains(current)
                else {
                    // Measured, not taken from a success record: the user
                    // can decline the macOS prompt. Keeping the current
                    // handler (skipped) counts as done.
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
            // Group membership decides, whatever the record says.
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

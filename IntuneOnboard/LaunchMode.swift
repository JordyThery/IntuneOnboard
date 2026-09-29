import Foundation

/// How the app was launched. Decides which UI is shown and how the window is presented.
enum LaunchMode: Equatable, Sendable {
    case setupAssistant
    case user
    case demo(Demo)

    enum Demo: String, Sendable {
        case provisioning
        case onboarding
    }

    var description: String {
        switch self {
        case .setupAssistant: "setup-assistant"
        case .user: "user"
        case .demo(let demo): "demo-\(demo.rawValue)"
        }
    }

    /// Full-screen, above everything, with no way for the person in front of
    /// the Mac to get rid of it: the modes where the app stands in for the
    /// system UI while root work happens.
    var isKiosk: Bool {
        switch self {
        case .setupAssistant: true
        case .user, .demo: false
        }
    }
}

/// Parsed process arguments. `--mode setup-assistant|user`,
/// `--demo provisioning|onboarding`, `--launched-by <method>` (set by the
/// daemon/agents so the spike can log how the app was started), and the
/// spike-only `--window-level <raw>` override for iterating window levels
/// over Setup Assistant without rebuilding.
struct LaunchArguments: Sendable {
    let mode: LaunchMode
    let launchedBy: String
    let windowLevelOverride: Int?
    /// `--show-log`: opens the log panel at launch. Demo only, for reviewing
    /// its placement without having to press ⌘L.
    let showsLogAtLaunch: Bool
    /// `--focus`: forces `windowPosition: focus` in the onboarding demo, the
    /// only way to review the backdrop without deploying a profile.
    /// `--focus blur` turns the blur on too.
    let forcesFocusMode: Bool
    let forcesFocusBlur: Bool

    /// Parsed once: the app scene and the app delegate both need them.
    static let current = parse()

    static func parse(_ arguments: [String] = CommandLine.arguments) -> LaunchArguments {
        var mode: LaunchMode = .user
        var launchedBy = "direct"
        var windowLevelOverride: Int?
        var showsLogAtLaunch = false
        var forcesFocusMode = false
        var forcesFocusBlur = false

        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--mode":
                switch iterator.next() {
                case "setup-assistant": mode = .setupAssistant
                case "user": mode = .user
                default: break
                }
            case "--demo":
                if let raw = iterator.next(), let demo = LaunchMode.Demo(rawValue: raw) {
                    mode = .demo(demo)
                }
            case "--launched-by":
                if let method = iterator.next() {
                    launchedBy = method
                }
            case "--window-level":
                if let raw = iterator.next(), let level = Int(raw) {
                    windowLevelOverride = level
                }
            case "--show-log":
                showsLogAtLaunch = true
            case "--focus":
                forcesFocusMode = true
            case "blur" where forcesFocusMode:
                forcesFocusBlur = true
            default:
                break
            }
        }
        return LaunchArguments(
            mode: mode,
            launchedBy: launchedBy,
            windowLevelOverride: windowLevelOverride,
            showsLogAtLaunch: showsLogAtLaunch,
            forcesFocusMode: forcesFocusMode,
            forcesFocusBlur: forcesFocusBlur
        )
    }
}

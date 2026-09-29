import Foundation

/// How the app was launched; determines the UI and window behaviour.
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

    /// Full screen, above Setup Assistant, and not dismissable by the user.
    var isKiosk: Bool {
        switch self {
        case .setupAssistant: true
        case .user, .demo: false
        }
    }
}

/// Parsed arguments: `--mode setup-assistant|user`,
/// `--demo provisioning|onboarding`, `--launched-by <method>` (logged), and
/// `--window-level <n>` (testing).
struct LaunchArguments: Sendable {
    let mode: LaunchMode
    let launchedBy: String
    let windowLevelOverride: Int?
    /// `--show-log`: opens the log panel at launch (demo only).
    let showsLogAtLaunch: Bool
    /// `--focus [blur]`: previews `windowPosition: focus` in the onboarding demo.
    let forcesFocusMode: Bool
    let forcesFocusBlur: Bool

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

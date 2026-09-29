import Foundation

/// A provisioning (device provisioning) item.
public struct ProvisioningItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case installomator(label: String, options: [String])
        case script(ScriptSpec)
        case wait(seconds: Int, message: LocalizedText?)
        case awaitPath(path: String, condition: PathCondition)
    }

    public struct ScriptSpec: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            /// Written to a 0700 root-only temp dir at run time, removed after.
            case inline(String)
            /// Must be root-owned and not group/world-writable.
            case path(String)
        }

        public let source: Source
        public let interpreter: String
        public let arguments: [String]
        public let successExitCodes: [Int]
        /// stdout lines starting with `status:` update the row's status text.
        public let statusFromOutput: Bool

        public init(
            source: Source,
            interpreter: String = "/bin/zsh",
            arguments: [String] = [],
            successExitCodes: [Int] = [0],
            statusFromOutput: Bool = true
        ) {
            self.source = source
            self.interpreter = interpreter
            self.arguments = arguments
            self.successExitCodes = successExitCodes
            self.statusFromOutput = statusFromOutput
        }
    }

    public enum PathCondition: String, Sendable {
        case exists
        case absent
    }

    public let id: String
    public let kind: Kind
    public let title: LocalizedText?
    public let subtitle: LocalizedText?
    public let icon: IconSpec?
    public let required: Bool
    public let enabled: Bool
    public let timeout: Int
    public let validatePath: String?

    public init(
        id: String,
        kind: Kind,
        title: LocalizedText? = nil,
        subtitle: LocalizedText? = nil,
        icon: IconSpec? = nil,
        required: Bool = true,
        enabled: Bool = true,
        timeout: Int? = nil,
        validatePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.required = required
        self.enabled = enabled
        self.timeout = timeout ?? Self.defaultTimeout(for: kind)
        self.validatePath = validatePath
    }

    public static func defaultTimeout(for kind: Kind) -> Int {
        switch kind {
        case .installomator, .script: 1800
        case .wait(let seconds, _): seconds
        case .awaitPath: 300
        }
    }
}

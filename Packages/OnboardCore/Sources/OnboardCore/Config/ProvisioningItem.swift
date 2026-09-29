import Foundation

/// One provisioning step.
public struct ProvisioningItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case installomator(label: String, options: [String])
        case script(ScriptSpec)
        case wait(seconds: Int, message: LocalizedText?)
        case awaitPath(path: String, condition: PathCondition)
    }

    public struct ScriptSpec: Equatable, Sendable {
        public enum Source: Equatable, Sendable {
            /// Staged in a root-only temporary directory.
            case inline(String)
            /// Must be a regular file owned by root and not writable by group or others.
            case path(String)
        }

        public let source: Source
        public let interpreter: String
        public let arguments: [String]
        public let successExitCodes: [Int]
        /// Output lines starting with `status:` update the item's status text.
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

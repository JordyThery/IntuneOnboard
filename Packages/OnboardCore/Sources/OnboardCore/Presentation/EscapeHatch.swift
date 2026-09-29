import Foundation

/// The administrator shortcut ⌃⌥⌘Q, independent of AppKit so it can be tested.
public enum EscapeHatch {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let command = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        public static let required: Modifiers = [.control, .option, .command]
    }

    public static let key = "q"

    /// Control, Option, Command and Q. Shift is allowed; fn is not.
    public static func matches(modifiers: Modifiers, characters: String?) -> Bool {
        guard modifiers.isSuperset(of: .required) else { return false }
        guard !modifiers.contains(.function) else { return false }
        return characters?.lowercased() == key
    }
}

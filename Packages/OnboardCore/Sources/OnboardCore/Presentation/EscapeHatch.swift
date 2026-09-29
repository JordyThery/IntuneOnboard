import Foundation

/// The administrator escape hatch chord: **⌃⌥⌘Q**.
///
/// The predicate lives here, free of AppKit, because the modifier arithmetic
/// is the part that goes wrong — and a hatch that doesn't fire is discovered
/// on a stranded Mac in the field, not on a dev machine. The app maps
/// `NSEvent.modifierFlags` onto `Modifiers` and asks this.
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

    /// Control + Option + Command + Q. Shift is tolerated (caps lock, or a
    /// technician holding it), `fn` is not — on laptop keyboards fn+Q can
    /// arrive with unrelated characters.
    public static func matches(modifiers: Modifiers, characters: String?) -> Bool {
        guard modifiers.isSuperset(of: .required) else { return false }
        guard !modifiers.contains(.function) else { return false }
        return characters?.lowercased() == key
    }
}

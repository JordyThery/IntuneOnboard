import OnboardCore
import SwiftUI

/// How one row's outcome looks. `symbol == nil` means "show a spinner".
struct RowAppearance {
    let symbol: String?
    let tint: Color

    static func forOutcome(_ outcome: ItemOutcome, required: Bool) -> RowAppearance {
        switch outcome {
        case .pending:
            RowAppearance(symbol: "circle.dotted", tint: .secondary)
        case .running:
            RowAppearance(symbol: nil, tint: .accentColor)
        case .success:
            RowAppearance(symbol: "checkmark.circle.fill", tint: .green)
        case .skipped:
            RowAppearance(symbol: "minus.circle", tint: .secondary)
        case .failed:
            // An optional item failing is not a red flag: the marker ignores it.
            required
                ? RowAppearance(symbol: "exclamationmark.circle.fill", tint: .red)
                : RowAppearance(symbol: "exclamationmark.circle", tint: .orange)
        }
    }
}

extension Color {
    /// Parses the `#RRGGBB` form the configuration uses for
    /// `organization.accentColor`. Returns nil for anything else.
    init?(hexRGB: String) {
        let digits = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

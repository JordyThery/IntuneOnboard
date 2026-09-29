import SwiftUI

/// Shown in both stages when `dryRun` is set. The text is the key name and
/// is not translated.
struct DryRunBadge: View {
    var body: some View {
        Text(verbatim: "DRY RUN")
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.yellow, in: Capsule())
            // A resource, so the lookup uses this module's bundle.
            .help(Text(.module("Dry run — nothing on this Mac is changed.", comment: "Tooltip on the DRY RUN badge, explaining that the run only looks like it is doing something.")))
            .accessibilityLabel(Text(.module("Dry run", comment: "Accessibility label for the DRY RUN badge.")))
    }
}

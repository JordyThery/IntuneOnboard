import SwiftUI

/// Worn by both stages whenever the profile's `dryRun` key is set, so a dry
/// run can never be mistaken for a real one — not in person, and not in a
/// screenshot. Deliberately loud; deliberately not themable. The badge text
/// itself is verbatim: it names the profile key, and a translated key helps
/// nobody grep a profile.
struct DryRunBadge: View {
    var body: some View {
        Text(verbatim: "DRY RUN")
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.yellow, in: Capsule())
            // Resources, not `String(localized:)`: these live in a package,
            // so the lookup needs the module's bundle, and resolving at
            // display time keeps the locale in effect then.
            .help(Text(.module("Dry run — nothing on this Mac is changed.", comment: "Tooltip on the DRY RUN badge, explaining that the run only looks like it is doing something.")))
            .accessibilityLabel(Text(.module("Dry run", comment: "Accessibility label for the DRY RUN badge.")))
    }
}

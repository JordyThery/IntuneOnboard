import AppKit
import OnboardCore
import SwiftUI

/// The active card's interaction area: one subview per kind. Lives inside the
/// card, under the step's title and description, so each subview is only the
/// interaction — the words are the card's.
struct OnboardingStepBody: View {
    let step: StepState
    let model: OnboardingViewModel

    var body: some View {
        if model.isWorking {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(OnboardingStrings.working)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            interaction
        }
    }

    @ViewBuilder
    private var interaction: some View {
        switch step.item.kind {
        case .message:
            MessageStep(step: step, model: model)
        case .wallpaper(let spec):
            WallpaperGrid(spec: spec, step: step, model: model)
        case .dock(let spec):
            DockChoice(spec: spec, step: step, model: model)
        case .defaultApps(let spec):
            DefaultAppsChoice(spec: spec, step: step, model: model)
        case .open(let target, let completion):
            OpenStep(step: step, target: target, completion: completion, model: model)
        case .demoteUser:
            DemoteStep(step: step, model: model)
        }
    }
}

// MARK: - message

/// Information only: the card already shows the title and the full message,
/// so there is nothing left to draw. Viewing it is completing it — the
/// auto-perform writes the record, Continue lights up, and the reader moves
/// on when they're done reading.
private struct MessageStep: View {
    let step: StepState
    let model: OnboardingViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: step.id) {
                if step.status == .suggested {
                    await model.perform()
                }
            }
    }
}

// MARK: - wallpaper

/// A grid of rounded wallpaper thumbnails; picking one applies it.
private struct WallpaperGrid: View {
    let spec: OnboardingItem.WallpaperSpec
    let step: StepState
    let model: OnboardingViewModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(spec.sources.enumerated()), id: \.offset) { index, source in
                    Button {
                        Task { await model.perform(choice: .wallpaper(sourceIndex: index)) }
                    } label: {
                        WallpaperThumbnail(source: source)
                    }
                    .buttonStyle(.plain)
                }
            }

            if spec.allowKeepExisting {
                Button(OnboardingStrings.keepCurrent) {
                    Task { await model.perform(choice: .keepCurrent) }
                }
                .buttonStyle(.link)
            }
        }
    }
}

private struct WallpaperThumbnail: View {
    let source: OnboardingItem.Source

    var body: some View {
        Group {
            switch source {
            case .path(let path):
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            }
        }
        .frame(width: 160, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    /// Missing file or unreachable URL: a quiet gradient rather than a broken
    /// image — routine before the daemon has downloaded remote sources.
    private var placeholder: some View {
        LinearGradient(
            colors: [.accentColor.opacity(0.45), .accentColor.opacity(0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

// MARK: - dock

/// The Dock as it *would look* after the chosen action — computed from the
/// user's current Dock, switching live with the radio, nothing applied until
/// the button. Previewing beats describing: "replace" and "merge" are hard to
/// tell apart in words and obvious side by side.
private struct DockChoice: View {
    let spec: OnboardingItem.DockSpec
    let step: StepState
    let model: OnboardingViewModel

    @State private var chosen: OnboardingItem.DockStrategy
    @State private var currentDock: [String] = []

    init(spec: OnboardingItem.DockSpec, step: StepState, model: OnboardingViewModel) {
        self.spec = spec
        self.step = step
        self.model = model
        _chosen = State(initialValue: spec.strategies.first ?? .add)
    }

    /// The preview simulates what the action would do, so it skips missing
    /// apps the same way the action will.
    private var recommendedPresent: [String] {
        spec.items.map(resolvedPath).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private var previewItems: [String] {
        DockPreview.items(current: currentDock, recommended: recommendedPresent, action: chosen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dockPreview

            if let record = step.record, record.outcome == .success,
               let added = record.detail["added"], let skipped = record.detail["skipped"] {
                Text(OnboardingStrings.dockOutcome(added: added, skipped: skipped))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if spec.strategies.count > 1 {
                    // `String()`, not "": the literal is a LocalizedStringKey
                    // and extraction plants an empty String Catalog entry.
                    Picker(String(), selection: $chosen) {
                        ForEach(spec.strategies, id: \.self) { action in
                            Text(OnboardingStrings.dockStrategyLabel(action)).tag(action)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Button {
                    Task { await model.perform(choice: .dock(chosen)) }
                } label: {
                    Text(OnboardingStrings.dockStrategyLabel(chosen))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .task { currentDock = await model.currentDockItems() }
    }

    /// Like the real Dock: Finder pinned left, Trash pinned right (dockutil
    /// manages neither, and a preview without them reads as wrong — user
    /// feedback from the first M4 run), with only the apps in between
    /// scrolling when they don't fit. A real Dock easily holds 15+ items, and
    /// on hardware a plain HStack bled past the material and out of the
    /// window.
    private var dockPreview: some View {
        HStack(spacing: 8) {
            ItemIcon(spec: .path("/System/Library/CoreServices/Finder.app"), size: 32)
            previewDivider

            ViewThatFits(in: .horizontal) {
                previewRow
                ScrollView(.horizontal, showsIndicators: false) {
                    previewRow
                }
            }

            if let trash = Self.trashImage {
                previewDivider
                Image(nsImage: trash)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.default, value: previewItems)
    }

    private var previewRow: some View {
        HStack(spacing: 8) {
            ForEach(previewItems, id: \.self) { path in
                ItemIcon(spec: .path(path), size: 32)
            }
        }
    }

    private var previewDivider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(.separator)
            .frame(width: 1, height: 34)
    }

    /// The Dock's own empty-trash artwork. A private path, so it may move in
    /// a macOS release — the preview simply omits Trash when it does, rather
    /// than showing a generic substitute next to real icons.
    private static let trashImage: NSImage? = NSImage(
        contentsOfFile: "/System/Library/CoreServices/Dock.app/Contents/Resources/s-trashempty2@2x.png"
    )

    /// `bundleid:` entries resolve to their app's path for the preview;
    /// unresolvable ones read as missing, exactly as the action treats them.
    private func resolvedPath(_ item: String) -> String {
        guard item.hasPrefix("bundleid:") else { return item }
        let bundleID = String(item.dropFirst("bundleid:".count))
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? item
    }
}

/// The item's configured button title, or the kind's fallback. The profile's
/// title is already-resolved text from the plist; the fallback is ours and
/// stays a resource until it is rendered.
private func buttonLabel(for step: StepState, fallback: LocalizedStringResource) -> Text {
    if let title = step.item.buttonTitle?.resolved() {
        Text(title)
    } else {
        Text(fallback)
    }
}

// MARK: - defaultApps

/// Candidates as large selectable app icons — one icon renders as a
/// confirmation, several as a pick-one.
private struct DefaultAppsChoice: View {
    let spec: OnboardingItem.DefaultAppsSpec
    let step: StepState
    let model: OnboardingViewModel

    /// target key → picked bundle id; seeded with every sole candidate.
    @State private var picks: [String: String]

    /// Targets with their candidates filtered to what is actually
    /// installed. An absent app can't be picked, and a target
    /// with nothing installed doesn't render (derivation skips it too).
    private let actionable: [(target: DefaultAppTarget, candidates: [String])]

    /// target key → the app handling it right now. Only read when the step
    /// allows keeping it: "Keep current" is the one case where the user needs
    /// to see what current *is* before deciding.
    private let currentHandlers: [String: String]

    init(spec: OnboardingItem.DefaultAppsSpec, step: StepState, model: OnboardingViewModel) {
        self.spec = spec
        self.step = step
        self.model = model
        let installed = spec.targets.compactMap { target, candidates -> (DefaultAppTarget, [String])? in
            let present = candidates.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
            return present.isEmpty ? nil : (target, present)
        }
        self.actionable = installed

        // The current handler joins the candidates as a tile of its own, so
        // keeping it is a choice you can see rather than a link you take on
        // trust. Only where it is offered, and only when it isn't already
        // one of the configured candidates.
        var handlers: [String: String] = [:]
        if spec.allowKeepExisting {
            for (target, candidates) in installed {
                if let current = LiveOnboarding.currentHandler(for: target),
                   !candidates.contains(current) {
                    handlers[target.key] = current
                }
            }
        }
        self.currentHandlers = handlers

        var seeded: [String: String] = [:]
        for (target, candidates) in installed where candidates.count == 1 && handlers[target.key] == nil {
            seeded[target.key] = candidates[0]
        }
        _picks = State(initialValue: seeded)
    }

    private var everyTargetPicked: Bool {
        actionable.allSatisfy { picks[$0.target.key] != nil }
    }

    /// True when every pick is the app already handling that target. Sending
    /// those through `utiluti` would ask macOS to confirm a change that isn't
    /// one, so this is "keep current" by another route.
    private var picksAreAllCurrent: Bool {
        actionable.allSatisfy { picks[$0.target.key] == currentHandlers[$0.target.key] }
    }

    /// Candidates plus the current handler, when there is one to show.
    private func tiles(for entry: (target: DefaultAppTarget, candidates: [String])) -> [String] {
        guard let current = currentHandlers[entry.target.key] else { return entry.candidates }
        return entry.candidates + [current]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if actionable.isEmpty {
                // Nothing to act on: the step derives as skipped and Continue
                // enables by itself; this just says why.
                Text(OnboardingStrings.appsNotInstalled)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(actionable, id: \.target) { entry in
                let choices = tiles(for: entry)
                HStack(spacing: 22) {
                    ForEach(choices, id: \.self) { bundleID in
                        AppCandidate(
                            bundleID: bundleID,
                            isPicked: picks[entry.target.key] == bundleID,
                            isCurrent: currentHandlers[entry.target.key] == bundleID,
                            dimsUnpicked: choices.count > 1 && picks[entry.target.key] != nil
                        ) {
                            picks[entry.target.key] = bundleID
                        }
                    }
                }
            }

            if let explanation = spec.explanation?.resolved() {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The button grays out once the step is *measured* complete — the
            // system default actually changed (or "keep current" was chosen) —
            // not merely because it was pressed: utiluti exiting 0 only means
            // the request was made, and the user can still decline macOS's
            // prompt. Until then it stays live and Continue stays disabled.
            if !actionable.isEmpty { confirmRow }
        }
    }

    private var confirmRow: some View {
            HStack(spacing: 14) {
                Button {
                    Task {
                        await model.perform(choice: picksAreAllCurrent ? .keepCurrent : .defaultApps(picks))
                    }
                } label: {
                    buttonLabel(for: step, fallback: OnboardingStrings.confirm)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!everyTargetPicked || step.status == .completed)

                if spec.allowKeepExisting, step.status != .completed {
                    Button(OnboardingStrings.keepCurrent) {
                        Task { await model.perform(choice: .keepCurrent) }
                    }
                    .buttonStyle(.link)
                }
            }
    }
}

private struct AppCandidate: View {
    let bundleID: String
    let isPicked: Bool
    /// The app handling this target today, labelled as such.
    var isCurrent = false
    let dimsUnpicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ItemIcon(spec: .bundleID(bundleID), size: 64)
                Text(displayName)
                    .font(.callout)
                if isCurrent {
                    Text(OnboardingStrings.currentDefault)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPicked ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
            )
            .opacity(dimsUnpicked && !isPicked ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    /// The app's real name when it is installed; the id's last component when
    /// not — candidates for apps provisioning hasn't finished installing yet.
    /// displayName(atPath:) keeps ".app" when Finder shows extensions, so it
    /// comes off explicitly.
    private var displayName: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

// MARK: - open

private struct OpenStep: View {
    let step: StepState
    let target: OnboardingItem.OpenTarget
    let completion: OnboardingItem.OpenCompletion
    let model: OnboardingViewModel

    var body: some View {
        // Pressing this IS completing the step for the manual flavour —
        // launching is the act, and there is nothing to verify (that is
        // what validatePath is for). A separate "Mark as done" next to it
        // was redundant (user feedback from the first M4 run).
        Button {
            Task { await model.perform() }
        } label: {
            buttonLabel(for: step, fallback: OnboardingStrings.openButtonFallback)
        }
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - demoteUser

/// Automatic: runs when the step becomes active, no button. What the user
/// sees is the outcome — the card's own check — not a decision.
private struct DemoteStep: View {
    let step: StepState
    let model: OnboardingViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: step.id) {
                if step.status == .suggested, step.item.mode == .automatic, step.record?.outcome != .failed {
                    await model.perform()
                }
            }
    }
}

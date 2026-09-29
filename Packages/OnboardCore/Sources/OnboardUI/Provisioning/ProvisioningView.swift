import OnboardCore
import SwiftUI

/// The provisioning window, shown over Setup Assistant, at login, and in
/// `--demo provisioning`: a header with a count, one row per item, and a
/// footer with the progress bar, "About this Mac" and help.
public struct ProvisioningView: View {
    public enum Presentation: Sendable {
        /// Over Setup Assistant, filling a window sized to its panel.
        case kiosk
        /// In a normal window.
        case window

        /// Minimum window size. Small, so the window can match any panel size.
        public var minimumSize: CGSize {
            switch self {
            case .kiosk: CGSize(width: 420, height: 320)
            case .window: CGSize(width: 720, height: 540)
            }
        }
    }

    private let model: ProvisioningViewModel
    private let presentation: Presentation
    private let onDismiss: (() -> Void)?
    private let alwaysAllowsDismiss: Bool

    @State private var showsAbout = false
    @State private var showsHelp = false

    /// - Parameter alwaysAllowsDismiss: offer a way past a failed run even
    ///   when `allowContinueOnError` is false. Used when this view is shown
    ///   before onboarding.
    public init(
        model: ProvisioningViewModel,
        presentation: Presentation = .window,
        onDismiss: (() -> Void)? = nil,
        alwaysAllowsDismiss: Bool = false
    ) {
        self.model = model
        self.presentation = presentation
        self.onDismiss = onDismiss
        self.alwaysAllowsDismiss = alwaysAllowsDismiss
    }

    private var display: ProvisioningDisplay { model.display }

    private var brandColor: Color {
        display.header.accentColor.flatMap { Color(hexRGB: $0) } ?? Color(.sRGB, red: 0.06, green: 0.14, blue: 0.45)
    }

    public var body: some View {
        framed
            .tint(brandColor)
            .task { model.start() }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var framed: some View {
        switch presentation {
        case .kiosk:
            // The window is sized to Setup Assistant's panel by
            // WindowPresenter, so the content fills it.
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .ignoresSafeArea()
        case .window:
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listArea
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Header

    /// Title and count on the left, the organization on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                headline
                    .font(.headline)
                subline
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if display.dryRun {
                DryRunBadge()
            }

            identity
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var headline: some View {
        if let terminal = ProvisioningStrings.headline(for: display.phase) {
            Text(terminal)
        } else if let configured = display.header.title {
            Text(configured)
        } else {
            Text(ProvisioningStrings.defaultTitle)
        }
    }

    /// The item count, or what is being waited for.
    @ViewBuilder
    private var subline: some View {
        if display.totalCount > 0 {
            HStack(spacing: 6) {
                Text(ProvisioningStrings.progressCaption(
                    completed: display.completedCount,
                    total: display.totalCount
                ))
                .monospacedDigit()
                if display.failedCount > 0 {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(ProvisioningStrings.needsAttention(count: display.failedCount))
                        .foregroundStyle(.red)
                }
            }
        } else if let activity = ProvisioningStrings.activity(for: display.phase) {
            Text(activity)
        } else if let configured = display.header.message {
            Text(configured)
        } else {
            Text(ProvisioningStrings.defaultMessage)
        }
    }

    /// A small logo and the name. A symbol logo uses the accent colour.
    @ViewBuilder
    private var identity: some View {
        HStack(spacing: 8) {
            if let logo = display.header.logo {
                ItemIcon(spec: logo, size: 30)
            }
            if let organization = display.header.organizationName {
                Text(organization)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Rows

    /// One row per item, keeping the running item in view. Before items
    /// exist, a spinner and the current activity.
    @ViewBuilder
    private var listArea: some View {
        if display.rows.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                if let activity = ProvisioningStrings.activity(for: display.phase) {
                    Text(activity)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let terminal = ProvisioningStrings.headline(for: display.phase) {
                    Text(terminal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(display.rows.enumerated()), id: \.element.id) { index, row in
                            self.row(row).id(row.id)
                            if index < display.rows.count - 1 {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                    .animation(.default, value: display.rows)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: display.currentRow?.id) { _, current in
                    guard let current else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        scroller.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(_ row: ProvisioningDisplay.Row) -> some View {
        HStack(spacing: 13) {
            ItemIcon(spec: row.icon, size: 32)
                .frame(width: 32, height: 32)
                .opacity(row.outcome == .pending ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.body)
                    .fontWeight(row.outcome == .running ? .semibold : .regular)
                    .foregroundStyle(row.outcome == .pending ? .secondary : .primary)
                    .lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                statusText(for: row)
                    .font(.subheadline)
                    .foregroundStyle(row.outcome == .failed && row.required
                                     ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                glyph(for: row)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(Text(ProvisioningStrings.label(for: row.status)))
    }

    /// A script's `status:` text while the item runs; the outcome once it
    /// has finished.
    @ViewBuilder
    private func statusText(for row: ProvisioningDisplay.Row) -> some View {
        if row.outcome == .running, let text = row.statusText, !text.isEmpty {
            Text(text)
        } else {
            Text(ProvisioningStrings.label(for: row.status))
        }
    }

    @ViewBuilder
    private func glyph(for row: ProvisioningDisplay.Row) -> some View {
        let appearance = RowAppearance.forOutcome(row.outcome, required: row.required)
        if let symbol = appearance.symbol {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.tint)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 11) {
            ProgressView(value: display.fractionComplete)
                .progressViewStyle(.linear)
                .tint(brandColor)
                .frame(height: 6)
                .accessibilityLabel(ProvisioningStrings.progressCaption(
                    completed: display.completedCount,
                    total: display.totalCount
                ))

            caption
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            // Over Setup Assistant there are no buttons, so tell the user
            // whom to contact.
            if display.failedCount > 0, display.phase.isFinished {
                Text(display.header.supportText.map { ProvisioningStrings.contactSupport(details: $0) }
                    ?? ProvisioningStrings.contactSupportGeneric)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            if display.phase.isFinished, offersRetry || (onDismiss != nil && canDismiss) {
                buttons
            }

            furniture
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// "Microsoft Edge (step 2 of 4)" while running; the outcome once done.
    @ViewBuilder
    private var caption: some View {
        if let current = display.currentRow, display.totalCount > 0 {
            Text(ProvisioningStrings.stepCaption(
                item: current.title,
                step: min(display.completedCount + 1, display.totalCount),
                total: display.totalCount
            ))
        } else if display.failedCount > 0 {
            Text(ProvisioningStrings.failureCaption(count: display.failedCount))
                .foregroundStyle(.red)
        } else if display.totalCount > 0 {
            Text(ProvisioningStrings.progressCaption(
                completed: display.completedCount,
                total: display.totalCount
            ))
            .monospacedDigit()
        }
    }

    /// Device details and the help button.
    private var furniture: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                showsAbout.toggle()
            } label: {
                Text(ProvisioningStrings.aboutThisMac)
                    .font(.caption)
            }
            .buttonStyle(.link)
            .popover(isPresented: $showsAbout, arrowEdge: .bottom) {
                AboutThisMacPopover(device: display.deviceInfo, startedAt: display.startedAt)
            }

            Spacer(minLength: 12)

            Text(ProvisioningStrings.credit)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let help = display.header.help {
                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(ProvisioningStrings.helpButton)
                .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
                    HelpPopover(help: help)
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 12) {
            if offersRetry {
                Button(ProvisioningStrings.retry) {
                    Task { await model.retry() }
                }
                .disabled(model.isRetrying)
            }

            // Omitted, not disabled, when a failed run cannot be dismissed.
            if let onDismiss, canDismiss {
                Button(display.failedCount > 0 ? ProvisioningStrings.continueAnyway : ProvisioningStrings.done) {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var canDismiss: Bool {
        display.failedCount == 0 || display.allowContinueOnError || alwaysAllowsDismiss
    }

    /// Not in kiosk mode, where no one is at the keyboard; the failure is
    /// reported in the log and the custom attribute.
    private var offersRetry: Bool {
        presentation != .kiosk && display.canRetry
    }
}

// MARK: - Previews

/// A fixed snapshot, so previews do not animate.
private struct FixedProgressSource: ProgressProviding {
    let snapshot: ProgressSnapshot
    func currentSnapshot() async -> ProgressSnapshot? { snapshot }
    func requestRetry() async -> Bool { false }
}

@MainActor
private func previewModel(elapsed: Double, retried: Bool = false) -> ProvisioningViewModel {
    let base = DemoScenario.snapshot(atElapsed: elapsed, retried: retried)
    let model = ProvisioningViewModel(
        source: FixedProgressSource(snapshot: ProgressSnapshot(
            engineState: base.engineState,
            items: base.items,
            startedAt: Date.now.addingTimeInterval(-elapsed)
        )),
        loadConfiguration: { DemoScenario.configuration() },
        deviceInfo: DeviceInfo(
            computerName: "MacBook Air",
            modelIdentifier: "Mac15,13",
            serialNumber: "C304JQC4KM",
            osVersion: "Version 26.6.2 (Build 25G83)"
        )
    )
    model.start(pollInterval: .seconds(3600))
    return model
}

/// A stand-in for Setup Assistant's background, for kiosk previews.
private struct BackdropPreview<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.45, blue: 0.62), Color(red: 0.30, green: 0.55, blue: 0.50)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content
                .frame(width: 800, height: 600)
        }
        .frame(width: 1280, height: 800)
    }
}

#Preview("Kiosk — installing") {
    BackdropPreview {
        ProvisioningView(model: previewModel(elapsed: 10), presentation: .kiosk)
    }
}

#Preview("Kiosk — complete") {
    BackdropPreview {
        ProvisioningView(model: previewModel(elapsed: 30, retried: true), presentation: .kiosk)
    }
}

#Preview("Kiosk — failure") {
    BackdropPreview {
        ProvisioningView(model: previewModel(elapsed: 30), presentation: .kiosk, onDismiss: {})
    }
}

#Preview("Kiosk — preflight") {
    BackdropPreview {
        ProvisioningView(model: previewModel(elapsed: 0.5), presentation: .kiosk)
    }
}

#Preview("Window — complete") {
    ProvisioningView(model: previewModel(elapsed: 30, retried: true), onDismiss: {})
        .frame(width: 800, height: 600)
}

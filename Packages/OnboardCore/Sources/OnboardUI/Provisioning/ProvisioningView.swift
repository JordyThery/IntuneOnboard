import OnboardCore
import SwiftUI

/// Provisioning, the device provisioning screen: shown over Setup Assistant (or at
/// the login window) while the root daemon works, and in `--demo provisioning`
/// against a scripted run.
///
/// A plain vertical register: a header naming the Mac's setup and counting it,
/// one row per item with its state on the right, and a footer carrying the
/// progress bar and the things a technician actually needs — "About this Mac…"
/// and the help button with its QR code. It reads as a system utility rather
/// than a branded splash; the organization's logo is an identity mark in the
/// header, not a billboard.
///
/// Two presentations, one layout. Over Setup Assistant the window is Setup
/// Assistant's own panel rectangle, and a separate invisible window covers the
/// screen so the kiosk still holds.
public struct ProvisioningView: View {
    public enum Presentation: Sendable {
        /// Over Setup Assistant: the content fills a window sized to Setup
        /// Assistant's panel.
        case kiosk
        /// Ordinary window: the content fills it.
        case window

        /// The smallest the window may be. The kiosk has to be free to shrink
        /// to whatever panel Setup Assistant is drawing — a minimum larger
        /// than the panel would stop the window matching it, which is the one
        /// thing that must not happen on hardware nobody has measured.
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

    /// - Parameter alwaysAllowsDismiss: offer a way out of a failed run even
    ///   when `allowContinueOnError` is false. Set when this card stands in
    ///   front of onboarding at login: the person is there, the steps behind
    ///   the card are theirs to do, and refusing them a button strands them
    ///   with a window whose only action is Try again.
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
            // The window *is* Setup Assistant's panel — `WindowPresenter` sets
            // its frame from the real rectangle — so the content just fills it.
            // There is deliberately no geometry here: positioning a card
            // inside a screen-sized window meant guessing that window's
            // offset from the screen, and every version of the guess was a
            // few points out. Clicks elsewhere are `KioskBlocker`'s job.
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

    /// Title and count on the left, the organization's identity on the right.
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

    /// The count while there are items; before that, what is being waited on.
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

    /// The organization's mark, restrained: a small logo and the name. A
    /// symbol logo takes the accent instead of white-on-white.
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

    /// One row per item, the working one kept in view. Before the item list
    /// exists (connecting, waiting for the profile, preflight) the area holds
    /// a spinner and the activity line instead of sitting empty.
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

    /// A script's own `status:` line wins over the localized label while the
    /// item runs — it is the more specific truth. Once the item is settled the
    /// outcome is the truth: hardware showed "Installing Rosetta 2" sitting
    /// next to a green check because the script's last line outlived the run.
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

            // Over Setup Assistant a failed run has no buttons — there is
            // nobody to press them — so without this the screen states a
            // problem and offers nothing at all. Whoever is holding the Mac
            // needs to know the next move is a phone call.
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

    /// The keepers: the device details and a scannable route to the service
    /// desk. A technician standing at a Mac during Setup Assistant has no
    /// Terminal and no browser, so neither can be designed away.
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

            // A failed run is only dismissable when the profile says so; a
            // clean one always is. When it isn't, the button is left out
            // rather than shown dead — there is nothing to do here but read
            // the failure and call the service desk.
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

    /// Never in the kiosk. Over Setup Assistant there is nobody to decide to
    /// retry and nothing gained by waiting: enrollment should carry on, and
    /// the failure is in the log and the Intune attribute. Retrying is for a
    /// signed-in user (or an admin over XPC).
    private var offersRetry: Bool {
        presentation != .kiosk && display.canRetry
    }
}

// MARK: - Previews

/// Fixed snapshot, so previews don't animate and each shows exactly the state
/// it claims to.
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

/// Stands in for the Setup Assistant backdrop so the kiosk previews show what
/// the window actually sits on.
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

import AppKit
import OnboardCore
import SwiftUI

/// Onboarding, the per-user stage: every step visible at once as a card,
/// completed in place. The user sees the whole scope up front instead of
/// discovering it a row at a time; the active card opens to hold its own
/// interaction; a single Continue advances once the active step is satisfied.
/// No sidebar, no detail pane, no second thing to look at.
public struct OnboardingView: View {
    @State private var model: OnboardingViewModel
    private let onDismiss: (() -> Void)?

    public init(model: OnboardingViewModel, onDismiss: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.onDismiss = onDismiss
    }

    private var accent: Color {
        model.accentHex.flatMap { Color(hexRGB: $0) } ?? .accentColor
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            // The card list only exists once the engine has derived the
            // steps: populating a live ForEach under `.animation` fades the
            // cards in from nothing, and the very first frame the user (or a
            // preview snapshot) sees is an empty window with a counter.
            if model.steps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(model.steps) { step in
                                StepCard(step: step, model: model)
                                    .id(step.id)
                            }
                        }
                        .padding(.horizontal, 26)
                        .padding(.bottom, 20)
                        .animation(.default, value: model.steps.map(\.status))
                    }
                    .onChange(of: model.selectedID) { _, selected in
                        guard let selected else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scroller.scrollTo(selected, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            footer
        }
        // The same size as the provisioning window, so the two stages read as
        // one product. The ideal matters as much as the minimum: without it
        // SwiftUI resized the window to its own preference after
        // WindowPresenter had set it, which is how the first hardware run got
        // a ballooned window.
        .frame(minWidth: 800, idealWidth: 800, minHeight: 600, idealHeight: 600)
        .background(Color(.windowBackgroundColor))
        .tint(accent)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 9) {
            if model.isDryRun {
                DryRunBadge()
            }

            // The organization's logo when configured — the same artwork as
            // the provisioning header, so both stages carry one brand — else
            // the app icon.
            if let logo = model.headerLogo {
                ItemIcon(spec: logo, size: 42)
            } else {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 42, height: 42)
            }

            Text(model.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(OnboardingStrings.doneCounter(
                completed: model.completed.count,
                total: model.steps.count
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .padding(.horizontal, 26)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(ProvisioningStrings.credit)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            if model.allDone {
                Button(OnboardingStrings.done) {
                    onDismiss?()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                // The whole progression model: one button, disabled until the
                // active step is satisfied.
                Button(OnboardingStrings.continueButton) {
                    model.advance()
                }
                .disabled(!model.canContinue)
                .keyboardShortcut(model.canContinue ? .defaultAction : nil)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        // More below than above, and not symmetric on purpose: on hardware
        // the window's usable height runs ~14 pt short of the layout's idea
        // of it, and a symmetric footer put Doorgaan half under the bottom
        // edge. The old sidebar layout carried the same compensation.
        .padding(.bottom, 28)
    }
}

// MARK: - Card

/// One step as a card. Completed cards collapse to a line with a green check;
/// the active card opens and holds the step's own interaction; the rest wait,
/// clickable, so any step can be brought forward out of order — the queue
/// keeps a failed one reachable rather than blocking on it.
private struct StepCard: View {
    let step: StepState
    let model: OnboardingViewModel

    private var isDone: Bool { step.status == .completed }
    private var isActive: Bool { step.id == model.selectedID }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                // The per-step icon: the one thing that says at a glance what
                // a step is about before reading it.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDone ? AnyShapeStyle(Color.green.opacity(0.14))
                                 : AnyShapeStyle(.tint.opacity(0.13)))
                    .frame(width: 34, height: 34)
                    .overlay {
                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.green)
                        } else {
                            ItemIcon(spec: step.item.icon ?? .symbol("checklist"), size: 20)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(step.item.title?.resolved() ?? step.id)
                        .font(.headline)
                        .foregroundStyle(isDone ? .secondary : .primary)
                    // Only the open card shows its full body: a welcome
                    // paragraph in every collapsed card would push the other
                    // steps off the window.
                    if let subtitle = step.item.subtitle?.resolved() {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(isActive ? nil : 1)
                    }
                    if isActive, step.record?.outcome == .failed, let message = step.record?.message {
                        // One localized sentence carrying the reason, rather
                        // than a localized prefix glued to it: the two halves
                        // don't keep this order in every language.
                        Text(OnboardingStrings.failure(message: message))
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if !isDone, !isActive {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }

            if isActive {
                OnboardingStepBody(step: step, model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 47)
            }
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isActive ? AnyShapeStyle(.tint.opacity(0.55))
                                               : AnyShapeStyle(Color.primary.opacity(0.07)),
                                      lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if !isActive { model.select(step.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(step.item.title?.resolved() ?? step.id))
        // `verbatim:` — a bare "" is a *localizable* literal, and Xcode's
        // extraction plants an empty entry in the String Catalog for it.
        .accessibilityValue(isDone ? Text(OnboardingStrings.completedSection) : Text(verbatim: ""))
        .accessibilityAddTraits(isActive ? [] : .isButton)
    }
}

// MARK: - Previews

#Preview("Onboarding — demo") {
    OnboardingView(model: OnboardingViewModel(
        engine: DemoOnboarding.makeEngine(),
        accentHex: "#0F6CBD"
    ))
    .frame(width: 800, height: 600)
}

import AppKit
import OnboardCore
import SwiftUI

/// The ⌘L log panel: a narrow tall column with inline tabs, the message
/// given the width, and the time in its own column.
///
/// Its whole reason for existing is that during Setup Assistant there is no
/// Terminal and no Console — so when provisioning misbehaves in front of a
/// customer, this is the only way to see why without wiping the Mac.
public struct LogViewer: View {
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    @State private var selection = LogFile.app.id
    @State private var summarize = true
    @State private var lines: [LogLine] = []
    @State private var exported: URL?
    @State private var exportFailed = false

    private var file: LogFile {
        LogFile.all.first { $0.id == selection } ?? .app
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rows
            Divider()
            footer
        }
        .task(id: Refresh(file: selection, summarize: summarize)) {
            // Re-read while the panel is open: a run in progress keeps
            // writing, and a static snapshot would mislead.
            while !Task.isCancelled {
                lines = load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // `String()` picks the non-localizable overload: a literal ""
            // is a LocalizedStringKey, and extraction plants an empty entry
            // in the String Catalog for it.
            Picker(String(), selection: $selection) {
                ForEach(LogFile.all) { file in
                    Text(file.title).tag(file.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                Task { await export() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(ProvisioningStrings.exportLogs)
        }
        // Leading inset clears the traffic lights: the tabs sit in the
        // titlebar beside them.
        .padding(.leading, 72)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    private var rows: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text(file.id == LogFile.intune.id
                             ? ProvisioningStrings.intuneLogUnavailableText
                             : ProvisioningStrings.logUnavailableText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                    }
                    ForEach(lines) { line in
                        row(line)
                        Divider().opacity(0.4)
                    }
                }
            }
            .onChange(of: lines.last?.id) { _, last in
                // Follow the tail, which is where a live run is.
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .background(Color(.textBackgroundColor))
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.message)
                .font(.callout)
                .foregroundStyle(colour(for: line.level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let time = line.time {
                Text(time)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func colour(for level: LogLine.Level) -> Color {
        switch level {
        case .normal: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(ProvisioningStrings.summarize, isOn: $summarize)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(file.summaryPatterns.isEmpty)
                .help(file.summaryPatterns.isEmpty
                      ? ProvisioningStrings.alreadyTerse
                      : ProvisioningStrings.summarizeHelp)

            Spacer(minLength: 8)

            if exportFailed {
                Text(ProvisioningStrings.exportFailed)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if exported != nil {
                Text(ProvisioningStrings.exported)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(ProvisioningStrings.close, action: onClose)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Async because the unified-log capture shells out: enrollment's own
    /// story lives there rather than in any file, and it is worth the couple
    /// of seconds. The files are copied first, so a slow `log show` can never
    /// cost us the logs we already have.
    private func export() async {
        do {
            let folder = try LogInspection.export()
            exported = folder
            exportFailed = false
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            await LogInspection.captureMDMLog(into: folder)
        } catch {
            exportFailed = true
            OnboardLog.app.error("log export failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() -> [LogLine] {
        // An Intune log that doesn't exist yet is a normal state, not an
        // error: the agent arrives partway through enrollment.
        guard let url = file.resolvedURL() else { return [] }

        var text = LogInspection.removeNoise(
            LogInspection.tail(url),
            patterns: file.noisePatterns
        )
        if summarize, !file.summaryPatterns.isEmpty {
            text = LogInspection.summarize(text, patterns: file.summaryPatterns)
        }
        return LogInspection.lines(text, levels: file.levels)
    }

    /// Restarts the refresh loop when either input changes.
    private struct Refresh: Equatable {
        let file: String
        let summarize: Bool
    }
}

extension View {
    /// Small helper so views can react to a NotificationCenter name without
    /// each one wiring up a publisher.
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        task {
            for await _ in NotificationCenter.default.notifications(named: name).map({ _ in () }) {
                action()
            }
        }
    }
}

#Preview("Logs") {
    LogViewer(onClose: {})
}

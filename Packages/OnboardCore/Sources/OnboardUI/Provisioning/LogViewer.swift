import AppKit
import OnboardCore
import SwiftUI

/// The ⌘L log panel: tabs per log file, with times in a separate column.
/// During Setup Assistant it is the only way to view logs.
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
            // Re-read periodically while open.
            while !Task.isCancelled {
                lines = load()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // `String()` keeps an empty entry out of the String Catalog.
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
        // Leading inset for the window buttons; the tabs are in the title bar.
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
                // Keep the newest lines in view.
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

    /// Copies the log files, then captures the MDM unified log, which can
    /// take a few seconds.
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
        // Normal before Intune installs its agent.
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

    /// Restarts refreshing when either input changes.
    private struct Refresh: Equatable {
        let file: String
        let summarize: Bool
    }
}

extension View {
    /// Runs an action when a notification is posted.
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

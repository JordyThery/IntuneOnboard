import Foundation

/// The log panel's sources and parsing: this app's log, Installomator's,
/// the installer's and Intune's.
public struct LogFile: Identifiable, Equatable, Sendable {
    /// A fixed path, or the newest matching file in a directory (Intune names
    /// its logs by date).
    public enum Source: Equatable, Sendable {
        case file(URL)
        /// The most recently modified file with this extension in any of
        /// these directories.
        case newest(in: [URL], extension: String)
    }

    public let id: String
    public let title: String
    public let source: Source
    /// Substrings kept when Summarize is on; empty shows the whole file.
    public let summaryPatterns: [String]
    /// Lines containing these are always hidden in the panel. Export keeps
    /// the full files.
    public let noisePatterns: [String]
    /// How wording determines a line's level; see `LevelHeuristic`.
    public let levels: LogInspection.LevelHeuristic

    public init(
        id: String,
        title: String,
        source: Source,
        summaryPatterns: [String] = [],
        noisePatterns: [String] = [],
        levels: LogInspection.LevelHeuristic = .explicitOnly
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.summaryPatterns = summaryPatterns
        self.noisePatterns = noisePatterns
        self.levels = levels
    }

    /// The file to read, or nil if it does not exist yet (normal for Intune
    /// early in enrollment).
    public func resolvedURL(fileManager: FileManager = .default) -> URL? {
        switch source {
        case .file(let url):
            return fileManager.isReadableFile(atPath: url.path) ? url : nil
        case .newest(let directories, let extensionName):
            return Self.newestFile(in: directories, extension: extensionName, fileManager: fileManager)
        }
    }

    static func newestFile(
        in directories: [URL],
        extension extensionName: String,
        fileManager: FileManager
    ) -> URL? {
        directories
            .flatMap { directory -> [URL] in
                let contents = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                return (contents ?? []).filter { $0.pathExtension == extensionName }
            }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// This app's log, for both stages.
    public static let app = LogFile(
        id: "app",
        title: "Intune Onboard",
        source: .file(URL(filePath: "/var/log/IntuneOnboard/onboard.log")),
        levels: .ourPhrasing
    )

    /// Installomator's own log file; its standard output stops after the
    /// start banner.
    public static let installomator = LogFile(
        id: "installomator",
        title: "Installomator",
        source: .file(URL(filePath: "/var/log/Installomator.log")),
        // REQ lines are the relevant ones; INFO is verbose.
        summaryPatterns: ["REQ", "ERROR", "WARN"]
    )

    public static let installer = LogFile(
        id: "installer",
        title: "Installer",
        source: .file(URL(filePath: "/var/log/install.log")),
        summaryPatterns: [
            "IntuneOnboard", "intuneonboard",
            "Installed", "install failed", "Install Failed", "Error",
        ],
        noisePatterns: installerNoise
    )

    /// install.log lines that contain "Error" but are not failures:
    ///
    /// - `IFJS: Package Authoring Error`, logged many times by Microsoft
    ///   installers that succeed.
    /// - `_buildInstallPlanReturningError:`, logged by `installd` for every
    ///   install plan.
    static let installerNoise = [
        "IFJS:",
        "allow-external-scripts",
        "_buildInstallPlanReturningError",
        "PackageKit: Adding client PKInstallDaemonClient",
        "PackageKit: Enqueuing install",
        // Installer sandbox paths, which also match this app's bundle id.
        "InstallerSandboxes",
        "will be atomically shoved",
        // softwareupdated is unavailable during Setup Assistant, so
        // mobileassetd logs repeated connection errors. (Rosetta 2 installs
        // can fail at this point for the same reason.)
        "SUPreferenceManager",
        "softwareupdated was invalidated",
        // Logged by Erase All Content and Settings, before the run.
        "mobile_obliterator",
    ]

    /// The newest Intune agent log. The directory appears once Intune
    /// installs its agent; Company Portal's log appears after first login.
    /// MDM activity is in the unified log; see `LogInspection.captureMDMLog`.
    public static let intune = LogFile(
        id: "intune",
        title: "Intune",
        source: .newest(
            in: [
                URL(filePath: "/Library/Logs/Microsoft/Intune"),
                URL(filePath: "/Library/Application Support/Microsoft/Intune/SideCar/logs"),
                URL(filePath: NSHomeDirectory()).appending(path: "Library/Logs/Company Portal"),
            ],
            extension: "log"
        ),
        summaryPatterns: ["Error", "error", "Warning", "warn", "profile", "Profile", "enroll"],
        noisePatterns: intuneNoise
    )

    /// Intune reading a script's stderr stream: routine, despite the word
    /// "error".
    static let intuneNoise = [
        "Starting reading error stream",
        "Finished reading error stream",
    ]

    public static let all: [LogFile] = [.app, .installomator, .installer, .intune]
}

/// One displayed log line. Times are kept as strings; they are only displayed.
public struct LogLine: Identifiable, Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case normal, warning, error
    }

    public let id: Int
    public let time: String?
    public let message: String
    public let level: Level

    public init(id: Int, time: String?, message: String, level: Level = .normal) {
        self.id = id
        self.time = time
        self.message = message
        self.level = level
    }
}

public enum LogInspection {
    /// How much a line's wording can mark it as an error.
    public enum LevelHeuristic: Sendable {
        /// This app's log: "failed", "could not" and "unable to" are errors.
        case ourPhrasing
        /// Other logs: only explicit error markers, since paths such as
        /// `Microsoft Error Reporting.app` are common.
        case explicitOnly
    }

    /// Splits log text into lines, extracting timestamps and removing
    /// repeated prefixes.
    public static func lines(_ text: String, levels: LevelHeuristic = .explicitOnly) -> [LogLine] {
        // Created per call; date formatters are not Sendable.
        let clock = ClockReader()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated()
            .compactMap { index, raw in
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                let (time, rest) = splitTimestamp(line, clock: clock)
                let (message, level) = cleanMessage(rest, levels: levels)
                guard !message.isEmpty else { return nil }
                return LogLine(id: index, time: time, message: message, level: level)
            }
    }

    /// Reads the three timestamp formats: ISO 8601 (this app,
    /// `2026-09-17T08:53:37.895Z`), Installomator's (`2026-09-17 01:53:38 :`)
    /// and install.log's (`2026-09-17 14:51:23+02:00`, sometimes with an
    /// hour-only offset such as `-07`). Times with a zone are converted to
    /// local time, so tabs can be compared.
    private static func splitTimestamp(_ line: String, clock: ClockReader) -> (String?, String) {
        guard let match = line.prefixMatch(
            of: /(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)?\s*/
        ) else {
            // Syslog-style lines (`Sep 18 17:22:26 host proc[99]: …`): keep
            // only the time.
            if let syslog = line.prefixMatch(of: /[A-Z][a-z]{2}\s+\d{1,2}\s+(\d{2}:\d{2}:\d{2})\s+/) {
                return (String(syslog.output.1), String(line[syslog.range.upperBound...]))
            }
            return (nil, line)
        }
        let rest = String(line[match.range.upperBound...])
        let written = String(match.output.2)
        guard let zone = match.output.4 else {
            // No zone: already local.
            return (written, rest)
        }
        // ISO8601DateFormatter needs ±hh:mm or ±hhmm, not ±hh.
        let normalized = zone.count == 3 ? "\(zone):00" : String(zone)
        let stamp = "\(match.output.1)T\(written)\(match.output.3 ?? "")\(normalized)"
        return (clock.localTime(ofISO8601: stamp) ?? written, rest)
    }

    /// Formats a zoned timestamp in local time.
    private final class ClockReader {
        private let plain: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private let fractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private let local: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            formatter.timeZone = .current
            return formatter
        }()

        func localTime(ofISO8601 stamp: String) -> String? {
            guard let date = fractional.date(from: stamp) ?? plain.date(from: stamp) else {
                return nil
            }
            return local.string(from: date)
        }
    }

    /// Removes Installomator's `: LEVEL : label :` and install.log's
    /// `host process[pid]:` prefixes, keeping the level.
    private static func cleanMessage(
        _ text: String,
        levels: LevelHeuristic
    ) -> (String, LogLine.Level) {
        var message = text
        var explicit: LogLine.Level?

        if let match = message.prefixMatch(of: /:\s*(REQ|INFO|DEBUG|WARN|ERROR)\s*:\s*([^:]+):\s*/) {
            switch match.output.1 {
            case "ERROR": explicit = .error
            case "WARN": explicit = .warning
            default: explicit = LogLine.Level.normal
            }
            message = String(message[match.range.upperBound...])
        } else if let match = message.prefixMatch(of: /\S+\s+[\w.\-]+\[\d+\]:\s*/) {
            message = String(message[match.range.upperBound...])
        }

        message = message.trimmingCharacters(in: .whitespaces)
        return (message, explicit ?? level(of: message, levels: levels))
    }

    /// Marks a line as an error when its wording describes a failure, not
    /// merely when it contains the word.
    private static func level(of message: String, levels: LevelHeuristic) -> LogLine.Level {
        // "Code=0" errors report success.
        if message.firstMatch(of: /(?i)code=0\b|undefined error: 0/) != nil {
            return .normal
        }

        // Explicit markers: an error object, an "error:" label, or a line
        // starting with a failure.
        let hardError = /(?i)^(error|failure|failed)\b|\berror\s*[:=]|\bfailed to\b|\berror domain=/
        if message.firstMatch(of: hardError) != nil {
            return .error
        }
        guard case .ourPhrasing = levels else { return .normal }

        // Wording this app uses.
        if message.firstMatch(of: /(?i)\bfailed\b|\bcould not\b|\bunable to\b|\brefused\b/) != nil {
            return .error
        }
        if message.firstMatch(of: /(?i)\bwarn(ing)?\b/) != nil {
            return .warning
        }
        return .normal
    }

    /// Reads the end of a file; install.log can be tens of megabytes.
    public static func tail(_ url: URL, maxBytes: Int = 256_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            // Drop the partial first line.
            if offset > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return text
        } catch {
            return ""
        }
    }

    /// Keeps lines containing any of `patterns`; all lines if none.
    public static func summarize(_ text: String, patterns: [String]) -> String {
        guard !patterns.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in patterns.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    /// Removes lines matching `patterns`. Applied whether or not Summarize
    /// is on.
    public static func removeNoise(_ text: String, patterns: [String]) -> String {
        guard !patterns.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !patterns.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    /// Copies the log files into a timestamped folder in `/Users/Shared`,
    /// which is writable during Setup Assistant and persists afterwards.
    @discardableResult
    public static func export(
        _ files: [LogFile] = LogFile.all,
        to parent: URL = URL(filePath: "/Users/Shared"),
        now: Date = .now
    ) throws -> URL {
        let stamp = now.formatted(
            .verbatim(
                "\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)\(second: .twoDigits)",
                timeZone: .current,
                calendar: .current
            )
        )
        let folder = parent.appending(path: "IntuneOnboardLogs-\(stamp)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Several tabs can read the same file. Copies are unfiltered.
        for url in Set(files.compactMap { $0.resolvedURL() }) {
            let destination = folder.appending(path: url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.copyItem(at: url, to: destination)
        }
        return folder
    }

    /// Writes the last hour of MDM activity from the unified log into the
    /// export folder. On failure, the error text is written instead.
    @discardableResult
    public static func captureMDMLog(
        into folder: URL,
        lastMinutes: Int = 60,
        timeout: Duration = .seconds(20),
        runner: ProcessRunning = LiveProcessRunner()
    ) async -> URL {
        let destination = folder.appending(path: "mdm-unified-log.txt")
        let predicate = """
        process == "mdmclient" OR process == "profiles" \
        OR subsystem CONTAINS "intune" OR subsystem == "com.apple.ManagedClient"
        """

        let body: String
        do {
            let result = try await runner.run(
                executable: "/usr/bin/log",
                arguments: [
                    "show", "--last", "\(lastMinutes)m",
                    "--predicate", predicate, "--style", "compact",
                ],
                environment: nil,
                timeout: timeout,
                lineHandler: nil
            )
            body = result.standardOutput.isEmpty
                ? "no matching entries (exit \(result.exitCode), timedOut=\(result.timedOut))\n\(result.standardError)"
                : result.standardOutput
        } catch {
            body = "could not run /usr/bin/log: \(error.localizedDescription)"
        }

        try? body.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}

public extension Notification.Name {
    /// Posted by the ⌘L shortcut.
    static let onboardShowLog = Notification.Name("be.jordythery.intuneonboard.showLog")
}

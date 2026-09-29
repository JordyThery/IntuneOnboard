import Foundation

/// The tabs behind ⌘L: our own log, Installomator's, the installer's and
/// Intune's — the places an enrollment goes wrong. Everything here is pure file
/// reading and parsing, so it can be tested.
public struct LogFile: Identifiable, Equatable, Sendable {
    /// Where the log lives. Some logs are a known path; Intune's are named
    /// after the moment they were opened, so those have to be searched for.
    public enum Source: Equatable, Sendable {
        case file(URL)
        /// The most recently modified file with this extension, across
        /// whichever of these directories exists.
        case newest(in: [URL], extension: String)
    }

    public let id: String
    public let title: String
    public let source: Source
    /// Substrings worth keeping when "Summarize" is on. Empty means the file
    /// is already terse enough to show whole.
    public let summaryPatterns: [String]
    /// Lines containing any of these are dropped *whether or not* Summarize is
    /// on: they are known chatter, not findings. The export copies the raw
    /// files, so nothing is actually lost.
    public let noisePatterns: [String]
    /// How freely this file's wording may colour a line red. Only our own log
    /// earns the benefit of the doubt; see `LogInspection.LevelHeuristic`.
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

    /// The file to read now, or `nil` when there is nothing to read — an
    /// Intune log that doesn't exist yet is a normal state during provisioning, not
    /// an error.
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

    /// Our own log, covering both stages — hence the product name rather than
    /// a stage name, which would read as "only the onboarding stage".
    public static let app = LogFile(
        id: "app",
        title: "Intune Onboard",
        source: .file(URL(filePath: "/var/log/IntuneOnboard/onboard.log")),
        levels: .ourPhrasing
    )

    /// Installomator's own log, not our captured copy of its stdout: it
    /// reassigns stdout after the start banner, so this file is the only place
    /// its download and install progress appears. Two Installomator tabs was
    /// one too many.
    public static let installomator = LogFile(
        id: "installomator",
        title: "Installomator",
        source: .file(URL(filePath: "/var/log/Installomator.log")),
        // Chatty at INFO; REQ is its own "worth reading" level.
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

    /// Two families of install.log line that read as failures and are not.
    ///
    /// `IFJS: Package Authoring Error` — Microsoft's package scripts emit one
    /// per path their InstallerJS touches, hundreds while Office installs.
    /// Apple deprecated `allow-external-scripts`; the install succeeds anyway.
    ///
    /// `_buildInstallPlanReturningError:` — `installd` logging the install
    /// plan it just built, once per component, with the package URL attached.
    ///
    /// Both match on the word "Error", so the summary kept every one of them
    /// and they crowded out the lines that matter. The export copies the raw
    /// file, so this only affects what the panel shows.
    static let installerNoise = [
        "IFJS:",
        "allow-external-scripts",
        "_buildInstallPlanReturningError",
        "PackageKit: Adding client PKInstallDaemonClient",
        "PackageKit: Enqueuing install",
        // PackageKit's sandbox scaffolding. Every one of these lines carries a
        // full /Library/InstallerSandboxes/.PKInstallSandboxManager/<uuid>
        // path, which wraps to three lines in the panel — and because the path
        // ends in our own bundle id they matched the "IntuneOnboard" summary
        // pattern, so our own pkg install filled the tab with its own
        // plumbing. "Writing receipt for" survives: that one is an outcome.
        "InstallerSandboxes",
        "will be atomically shoved",
        // `mobileassetd` cannot reach com.apple.softwareupdated during Setup
        // Assistant ("Connection init failed at lookup with error 3 - No such
        // process"), and logs a multi-line NSError about it repeatedly. It has
        // nothing to do with our installs, and each one filled a third of the
        // panel. NOTE: this is also the reason an item that needs
        // `softwareupdate` — Rosetta 2 — can fail this early in a run.
        "SUPreferenceManager",
        "softwareupdated was invalidated",
        // The wipe, logged before onboarding existed: `mobile_obliterator`
        // runs during Erase All Content and Settings, so its lines predate
        // the run being diagnosed and are never about it.
        "mobile_obliterator",
    ]

    /// Intune writes per-session files named after the time they were opened,
    /// so the newest one is the live one.
    ///
    /// `/Library/Logs/Microsoft/Intune` is the device-level MDM agent, which
    /// is what matters during provisioning — though it only exists once Intune has
    /// installed the agent, so an empty tab early in a run is expected and is
    /// itself informative. Company Portal's is user-level and appears after
    /// first login.
    ///
    /// Enrollment itself (`mdmclient`) goes to the unified log rather than any
    /// file; `LogInspection.captureMDMLog` picks that up for the export.
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

    /// `ScriptOrchestrationLogger | Starting reading error stream …` and its
    /// Finished twin are Intune's agent reading a script's *stderr pipe* —
    /// bookkeeping, not a failure. They say "error", so they were both kept by
    /// the summary and coloured red, which made a healthy enrollment look like
    /// it was throwing errors every second.
    static let intuneNoise = [
        "Starting reading error stream",
        "Finished reading error stream",
    ]

    public static let all: [LogFile] = [.app, .installomator, .installer, .intune]
}

/// One rendered row: the message given the width, and the time in its own
/// column so scanning down it is easy. Timestamps are strings because they are
/// only ever displayed — parsing them into `Date` just to format them back
/// would invite time-zone bugs for no gain.
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
    /// Splits raw log text into rows, lifting the timestamp out of whichever
    /// format the file uses and dropping the repeated scaffolding so the
    /// message can have the width.
    /// How much a line's wording is allowed to colour it red.
    public enum LevelHeuristic: Sendable {
        /// Our own log, where we write the phrasing: "failed", "could not"
        /// and "unable to" really do mean something went wrong.
        case ourPhrasing
        /// Third-party logs: only unmistakable markers count. install.log is
        /// full of paths like `Microsoft Error Reporting.app` and lines like
        /// "Registered bundle …/Microsoft%20Error%20Reporting.app", none of
        /// which is a failure — and a wall of false red is worse than no
        /// colour at all, because nothing stands out any more.
        case explicitOnly
    }

    public static func lines(_ text: String, levels: LevelHeuristic = .explicitOnly) -> [LogLine] {
        // Built per call, not stored: the date formatters aren't Sendable
        // (the same constraint `RotatingFileSink` documents), and one set for
        // a whole file is cheap.
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

    /// Handles the three formats we show: our ISO8601
    /// (`2026-09-17T08:53:37.895Z …`), Installomator's
    /// (`2026-09-17 01:53:38 : …`) and install.log's
    /// (`2026-09-17 14:51:23+02:00 …`).
    ///
    /// A zone-qualified stamp is converted to this Mac's time. Our own file
    /// log writes UTC (`Z`), which is the right thing for a log file but was
    /// being shown verbatim — so the Onboarding tab read two hours off the
    /// menu bar next to Installomator's local times, and seven hours off at
    /// the login window, where the Mac's time zone isn't set yet. Comparing
    /// tabs to find what happened when is the whole job of this panel.
    /// install.log writes an hour-only offset (`+02`, or `-07` on a Mac whose
    /// time zone Setup Assistant hasn't set yet), so the minutes are
    /// optional — leaving them out of the pattern stranded a `-07` at the
    /// head of every installer line and defeated the prefix strip below.
    private static func splitTimestamp(_ line: String, clock: ClockReader) -> (String?, String) {
        guard let match = line.prefixMatch(
            of: /(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}(?::?\d{2})?)?\s*/
        ) else {
            // install.log mixes in syslog-style lines —
            // `Sep 18 17:22:26 host proc[99]: …` — which carry no year and
            // no zone. Lifting the clock out is all that's wanted; they were
            // showing their date, hostname and pid inside the message.
            if let syslog = line.prefixMatch(of: /[A-Z][a-z]{2}\s+\d{1,2}\s+(\d{2}:\d{2}:\d{2})\s+/) {
                return (String(syslog.output.1), String(line[syslog.range.upperBound...]))
            }
            return (nil, line)
        }
        let rest = String(line[match.range.upperBound...])
        let written = String(match.output.2)
        guard let zone = match.output.4 else {
            // No zone: already local (Installomator writes it that way).
            return (written, rest)
        }
        // ISO8601DateFormatter wants ±hh:mm or ±hhmm, never a bare ±hh.
        let normalized = zone.count == 3 ? "\(zone):00" : String(zone)
        let stamp = "\(match.output.1)T\(written)\(match.output.3 ?? "")\(normalized)"
        return (clock.localTime(ofISO8601: stamp) ?? written, rest)
    }

    /// Renders a zone-qualified stamp as this Mac's wall clock.
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

    /// Installomator repeats `: LEVEL : label :` on every line; install.log
    /// repeats `host process[pid]:`. Neither earns its width in a narrow
    /// panel, so they come off — but the level is kept for colour.
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

    /// Colour when the wording is *about* a failure, not merely when the
    /// letters appear in it. Installer lines like "Registered bundle
    /// …/Microsoft Error Reporting.app for uid 0" were turning the whole
    /// panel red, which hides the one line that matters.
    private static func level(of message: String, levels: LevelHeuristic) -> LogLine.Level {
        // An error object carrying code 0 is macOS reporting success in the
        // shape of a failure — `mobile_obliterator` logs
        // `(error Error Domain=NSPOSIXErrorDomain Code=0 "Undefined error: 0")`
        // for folders it created perfectly well.
        if message.firstMatch(of: /(?i)code=0\b|undefined error: 0/) != nil {
            return .normal
        }

        // Unmistakable in anybody's log: a thrown error object, a labelled
        // error, or a message that opens by announcing the failure.
        let hardError = /(?i)^(error|failure|failed)\b|\berror\s*[:=]|\bfailed to\b|\berror domain=/
        if message.firstMatch(of: hardError) != nil {
            return .error
        }
        guard case .ourPhrasing = levels else { return .normal }

        // Our own wording, from the lines this app actually writes.
        if message.firstMatch(of: /(?i)\bfailed\b|\bcould not\b|\bunable to\b|\brefused\b/) != nil {
            return .error
        }
        if message.firstMatch(of: /(?i)\bwarn(ing)?\b/) != nil {
            return .warning
        }
        return .normal
    }

    /// Reads the *end* of a file. install.log is routinely tens of megabytes,
    /// and a log viewer that stalls the UI to show a wall of boot messages
    /// helps nobody.
    public static func tail(_ url: URL, maxBytes: Int = 256_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            // A partial first line is noise; drop it.
            if offset > 0, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return text
        } catch {
            return ""
        }
    }

    /// Keeps only lines containing one of `patterns`. With no patterns the
    /// text is already terse and comes back whole.
    public static func summarize(_ text: String, patterns: [String]) -> String {
        guard !patterns.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in patterns.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    /// Drops known chatter. Applied before `summarize`, and regardless of it:
    /// these lines are never the answer to "why did this fail?", and left in
    /// they push the lines that are off the screen.
    public static func removeNoise(_ text: String, patterns: [String]) -> String {
        guard !patterns.isEmpty else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !patterns.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    /// Copies every readable log into a timestamped folder, the way Setup
    /// Manager's export does. `/Users/Shared` because it is writable even by
    /// `_mbsetupuser` during Setup Assistant, and survives the session ending.
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

        // De-duplicate: several tabs can be views onto one file. Raw copies,
        // deliberately — the panel filters noise for legibility, the export is
        // for someone who wants everything.
        for url in Set(files.compactMap { $0.resolvedURL() }) {
            let destination = folder.appending(path: url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.copyItem(at: url, to: destination)
        }
        return folder
    }

    /// Enrollment's own story is in the unified log, not in any file: profile
    /// installs, MDM commands and their errors come from `mdmclient`. Captured
    /// into the export because during Setup Assistant there is no Terminal to
    /// run `log show` in — and because "Intune says it pushed the profile" has
    /// already cost one debugging round.
    ///
    /// Written to the folder whatever happens: the error text is itself the
    /// finding if `log` refuses.
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
    /// Posted by the ⌘L key monitor in the app; the provisioning view listens.
    static let onboardShowLog = Notification.Name("be.jordythery.intuneonboard.showLog")
}

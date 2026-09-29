import Foundation

/// Mirrors log lines to a file, rotating at a size limit:
/// `onboard.log` → `onboard.log.1` → … up to `keepArchives`, oldest dropped.
/// os.Logger stays the primary sink; this file exists so a support tech can
/// grab logs from a machine without console access.
public final class RotatingFileSink: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let keepArchives: Int
    private let lock = NSLock()
    private var handle: FileHandle?

    // Instance property (not static): ISO8601DateFormatter isn't Sendable;
    // all access happens under `lock`.
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(fileURL: URL, maxFileSizeMB: Int = 10, keepArchives: Int = 3) {
        self.fileURL = fileURL
        self.maxBytes = maxFileSizeMB * 1_048_576
        self.keepArchives = max(0, keepArchives)
    }

    deinit {
        try? handle?.close()
    }

    /// Appends one line, prefixed with a timestamp. Failures are swallowed —
    /// file logging must never take the daemon down.
    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let handle = try openIfNeeded()
            let stamped = "\(timestampFormatter.string(from: .now)) \(line)\n"
            try handle.write(contentsOf: Data(stamped.utf8))
            if try handle.offset() > maxBytes {
                try rotate()
            }
        } catch {
            // Intentionally ignored; os.Logger remains the primary sink.
        }
    }

    private func openIfNeeded() throws -> FileHandle {
        if let handle { return handle }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // World-readable on purpose: the daemon writes these as root, and
            // the log viewer (⌘L) reads them from a user session — during
            // Setup Assistant that means _mbsetupuser. Relying on root's
            // umask for that would be an accident waiting to happen.
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o644]
            )
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        try opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil

        let manager = FileManager.default
        // Drop the oldest, shift the rest up, move the live file to .1.
        let oldest = archiveURL(index: keepArchives)
        if manager.fileExists(atPath: oldest.path) {
            try manager.removeItem(at: oldest)
        }
        if keepArchives > 0 {
            for index in stride(from: keepArchives - 1, through: 1, by: -1) {
                let source = archiveURL(index: index)
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: archiveURL(index: index + 1))
                }
            }
            try manager.moveItem(at: fileURL, to: archiveURL(index: 1))
        } else {
            try manager.removeItem(at: fileURL)
        }
    }

    private func archiveURL(index: Int) -> URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "\(fileURL.lastPathComponent).\(index)")
    }
}

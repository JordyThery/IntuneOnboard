import CryptoKit
import Foundation

/// The daemon's implementation of the onboarding root operations. The item,
/// URL and user are resolved from the daemon's own configuration and console
/// user. Errors are returned in the reply, not thrown, so they cross XPC.
public struct OnboardingRootOperations: Sendable {
    public var loadConfiguration: @Sendable () throws -> Configuration
    public var runner: any ProcessRunning
    public var consoleUserName: @Sendable () -> String?
    /// Downloads to a temporary file and returns its URL.
    public var download: @Sendable (URL) async throws -> URL
    public var fileManager: FileManager { .default }

    public init(
        loadConfiguration: @escaping @Sendable () throws -> Configuration,
        runner: any ProcessRunning = LiveProcessRunner(),
        consoleUserName: @escaping @Sendable () -> String? = { ConsoleUser.current()?.name },
        download: @escaping @Sendable (URL) async throws -> URL = { url in
            let (file, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return file
        }
    ) {
        self.loadConfiguration = loadConfiguration
        self.runner = runner
        self.consoleUserName = consoleUserName
        self.download = download
    }

    // MARK: - Wallpaper

    public func fetchWallpaper(itemID: String, sourceIndex: Int) async -> RootOperationReply {
        guard let item = onboardingItem(itemID),
              case .wallpaper(let spec) = item.kind,
              spec.sources.indices.contains(sourceIndex)
        else {
            return RootOperationReply(ok: false, message: "no such wallpaper source in the configuration")
        }
        guard case .remote(let url) = spec.sources[sourceIndex] else {
            // Local sources need no download.
            return RootOperationReply(ok: true, value: WallpaperLocation.destination(for: spec.sources[sourceIndex]).path)
        }

        let destination = WallpaperLocation.destination(for: spec.sources[sourceIndex])
        do {
            let temporary = try await download(url)
            defer { try? fileManager.removeItem(at: temporary) }

            // Verified before the file is moved into place.
            if let expected = spec.sha256 {
                let actual = try Hashing.sha256(of: temporary)
                guard actual == expected.lowercased() else {
                    return RootOperationReply(ok: false, message: "wallpaper hash mismatch")
                }
            }

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            // Readable by all users, writable only by root.
            try fileManager.setAttributes([
                .posixPermissions: 0o644,
                .ownerAccountID: 0,
                .groupOwnerAccountID: 0,
            ], ofItemAtPath: destination.path)
            OnboardLog.daemon.notice("wallpaper downloaded to \(destination.path, privacy: .public)")
            return RootOperationReply(ok: true, value: destination.path)
        } catch {
            OnboardLog.daemon.error("wallpaper download failed: \(error.localizedDescription, privacy: .public)")
            return RootOperationReply(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Demotion

    public func demoteConsoleUser(itemID: String) async -> RootOperationReply {
        guard let item = onboardingItem(itemID),
              case .demoteUser(let exclude) = item.kind
        else {
            return RootOperationReply(ok: false, message: "no such demoteUser item in the configuration")
        }
        guard let user = consoleUserName() else {
            return RootOperationReply(ok: false, message: "no console user")
        }
        // Enforced here, not in the UI.
        guard !exclude.contains(user) else {
            return RootOperationReply(ok: true, value: "notNeeded", message: "\(user) is excluded")
        }

        do {
            // Prefix match: "no reyes is NOT a member" contains "yes".
            let membership = try await dseditgroup(["-o", "checkmember", "-m", user, "admin"])
            guard membership.standardOutput.hasPrefix("yes") else {
                return RootOperationReply(ok: true, value: "notNeeded")
            }
            let edit = try await dseditgroup(["-o", "edit", "-d", user, "-t", "user", "admin"])
            guard edit.exitCode == 0 else {
                return RootOperationReply(ok: false, message: "dseditgroup exited \(edit.exitCode)")
            }
            OnboardLog.daemon.notice("demoted \(user, privacy: .public) from the admin group")
            return RootOperationReply(ok: true, value: "demoted")
        } catch {
            return RootOperationReply(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: - Shared

    private func onboardingItem(_ id: String) -> OnboardingItem? {
        (try? loadConfiguration())?.onboarding?.items.first { $0.id == id }
    }

    private func dseditgroup(_ arguments: [String]) async throws -> ProcessResult {
        try await runner.run(
            executable: "/usr/sbin/dseditgroup",
            arguments: arguments,
            environment: nil,
            timeout: .seconds(30),
            lineHandler: nil
        )
    }
}

/// The XPC client implements the root operations protocol directly.
extension OnboardServiceClient: OnboardingRootServicing {}

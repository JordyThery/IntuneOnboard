import CryptoKit
import Foundation

/// The daemon's side of the two onboarding root operations. Everything is
/// resolved from the daemon's own inputs — its config, its view of the console
/// user — so the XPC caller supplies nothing but an item id and an index.
///
/// Returns `RootOperationReply` rather than throwing: the reply crosses XPC,
/// and the error text is the part the user ends up reading.
public struct OnboardingRootOperations: Sendable {
    public var loadConfiguration: @Sendable () throws -> Configuration
    public var runner: any ProcessRunning
    public var consoleUserName: @Sendable () -> String?
    /// Downloads to a temporary file and returns its URL (URLSession live).
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
            // A local path needs no download; answer with it.
            return RootOperationReply(ok: true, value: WallpaperLocation.destination(for: spec.sources[sourceIndex]).path)
        }

        let destination = WallpaperLocation.destination(for: spec.sources[sourceIndex])
        do {
            let temporary = try await download(url)
            defer { try? fileManager.removeItem(at: temporary) }

            // Config-pinned hash, verified before the file lands anywhere
            // shared. Only a single-source item can carry one (validator).
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
            // Readable by every user's onboarding, writable by nobody but root.
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
        // The exclude list is enforced *here*, from the daemon's own config —
        // not in the UI, whose process the user controls.
        guard !exclude.contains(user) else {
            return RootOperationReply(ok: true, value: "notNeeded", message: "\(user) is excluded")
        }

        do {
            // Prefix, not contains: the output is "yes <user> is a member…" /
            // "no <user> is NOT a member…", and a username containing "yes"
            // (reyes) would satisfy a contains check on the negative line.
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

/// The XPC client satisfies the actions' root protocol directly — same
/// signatures, same semantics.
extension OnboardServiceClient: OnboardingRootServicing {}

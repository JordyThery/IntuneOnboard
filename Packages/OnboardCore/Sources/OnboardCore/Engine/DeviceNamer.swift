import Foundation

/// Applies `deviceNameTemplate`: sets ComputerName to the rendered name, and
/// LocalHostName and HostName to its sanitized form, with `scutil`.
public struct DeviceNamer: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The names were set.
        case named(computerName: String, localHostName: String)
        /// Dry run: rendered, not applied.
        case dryRun(computerName: String)
        /// A token has no value on this Mac; nothing was changed.
        case valueUnavailable
        /// `scutil` failed.
        case failed(String)
    }

    public var runner: any ProcessRunning
    /// Token values; injectable for tests.
    public var value: @Sendable (NameTemplate.Token) -> String?

    public init(
        runner: any ProcessRunning = LiveProcessRunner(),
        value: @escaping @Sendable (NameTemplate.Token) -> String? = DeviceNamer.deviceValue
    ) {
        self.runner = runner
        self.value = value
    }

    public func apply(template: NameTemplate, dryRun: Bool) async -> Outcome {
        guard let name = template.render(value: value) else {
            return .valueUnavailable
        }
        guard let localHostName = NameTemplate.localHostName(from: name) else {
            // Nothing usable remains after sanitizing.
            return .valueUnavailable
        }
        if dryRun {
            return .dryRun(computerName: name)
        }

        for (key, target) in [
            ("ComputerName", name),
            ("LocalHostName", localHostName),
            ("HostName", localHostName),
        ] {
            do {
                let result = try await runner.run(
                    executable: "/usr/sbin/scutil",
                    arguments: ["--set", key, target],
                    environment: nil,
                    timeout: .seconds(30),
                    lineHandler: nil
                )
                guard result.exitCode == 0 else {
                    return .failed("scutil --set \(key) exited \(result.exitCode)")
                }
            } catch {
                return .failed("scutil --set \(key): \(error.localizedDescription)")
            }
        }
        return .named(computerName: name, localHostName: localHostName)
    }

    // MARK: - Live values

    /// `%model%`: the model family, e.g. "MacBook Air". Falls back to the
    /// model identifier when no product name is available.
    @Sendable
    public static func deviceValue(_ token: NameTemplate.Token) -> String? {
        switch token {
        case .serial:
            DeviceInfo.current().serialNumber
        case .udid:
            DeviceInfo.platformUUID()
        case .model:
            modelName()
        case .modelShort:
            modelName().split(separator: " ").first.map(String.init)
        }
    }

    private static func modelName() -> String {
        let info = DeviceInfo.current()
        guard let marketing = info.marketingName else { return info.modelIdentifier }
        // "MacBook Air (15-inch, M4, 2025)" → "MacBook Air".
        return marketing
            .prefix { $0 != "(" }
            .trimmingCharacters(in: .whitespaces)
    }
}

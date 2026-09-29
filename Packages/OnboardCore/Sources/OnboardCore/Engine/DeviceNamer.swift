import Foundation

/// Applies `provisioning.deviceNameTemplate`: renders the name from the
/// device and sets ComputerName (verbatim), plus LocalHostName and HostName
/// (Bonjour-sanitized) via `scutil`. Runs in the daemon — naming needs root —
/// once per run, before the items, so scripts that read the name see it.
public struct DeviceNamer: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The Mac now carries this name (ComputerName, and the sanitized
        /// LocalHostName/HostName).
        case named(computerName: String, localHostName: String)
        /// DEBUG: rendered but deliberately not applied.
        case dryRun(computerName: String)
        /// A token had no value on this device (a Mac with no readable
        /// serial, say). Never applies a partial name.
        case valueUnavailable
        /// scutil failed; the message names the command.
        case failed(String)
    }

    public var runner: any ProcessRunning
    /// Injectable device answers, keyed by template token.
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
            // A name of nothing but disallowed characters — treat like a
            // missing value rather than half-applying.
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

    /// `%model%` is the marketing family — "MacBook Air", not
    /// "MacBook Air (15-inch, M4, 2025)" and not "Mac15,13". The identifier
    /// stands in when the device tree carries no product name.
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
        // Strip the parenthetical: "MacBook Air (15-inch, M4, 2025)".
        return marketing
            .prefix { $0 != "(" }
            .trimmingCharacters(in: .whitespaces)
    }
}

import ArgumentParser
import Foundation
import OnboardCore

/// Query/maintenance subcommands for onboardd. The `run` entry point stays in
/// the daemon target (it owns session monitoring); main.swift dispatches
/// everything else here.
public enum OnboardCommands {
    public static func run(arguments: [String]) -> Never {
        Root.main(arguments)
        // ParsableCommand.main() calls exit() itself; this is unreachable
        // but satisfies Never on toolchains where main is typed () -> Void.
        exit(0)
    }

    struct Root: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "onboardd",
            abstract: "Intune Onboard daemon and management CLI.",
            subcommands: [ValidateConfig.self, Status.self, Reset.self],
            defaultSubcommand: nil
        )
    }
}

// MARK: - validate-config

struct ValidateConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-config",
        abstract: "Load and validate the configuration, printing every problem."
    )

    @Option(name: .customLong("path"), help: "Validate this plist instead of the managed preferences (must be root-owned).")
    var path: String?

    func run() throws {
        do {
            let configuration = try ConfigLoader.load(overridePath: path)
            let provisioningCount = configuration.provisioning?.items.count ?? 0
            let onboardingCount = configuration.onboarding?.items.count ?? 0
            print("OK — schemaVersion \(configuration.schemaVersion), \(provisioningCount) provisioning item(s), \(onboardingCount) onboarding item(s)")
        } catch let error as ConfigLoadError {
            print(error.description)
            throw ArgumentParser.ExitCode(1)
        }
    }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Summarize both stages (usable as an Intune custom attribute)."
    )

    @Flag(name: .customLong("json"), help: "Emit JSON instead of a single line.")
    var json = false

    func run() throws {
        let store = StateStore()
        let device = try? store.loadDeviceState()
        let onboarding = Self.consoleUserOnboarding()

        let ineligible = EnrollmentCheck.isIneligible(configuration: try? ConfigLoader.load())

        if json {
            try printJSON(device: device, onboarding: onboarding, store: store)
        } else {
            print(Self.singleLine(device: device, onboarding: onboarding, ineligible: ineligible))
        }
    }

    /// The onboarding state of whoever is at the keyboard. Reported because
    /// an attribute covering only the device half would say "complete" about
    /// a Mac whose user still has every step in front of them.
    ///
    /// `nil` user means there is nobody to report on: during provisioning the
    /// console belongs to Setup Assistant or the login window, which is a
    /// normal state rather than a fault.
    static func consoleUserOnboarding() -> (user: String, state: UserState?)? {
        guard let console = ConsoleUser.current(), console.isRealUser else { return nil }
        guard let store = StateStore.forUser(named: console.name) else { return nil }
        return (console.name, (try? store.loadUserState()) ?? nil)
    }

    /// One line, because that is what an Intune custom attribute stores and
    /// what an administrator reads in a list of hundreds of Macs.
    static func singleLine(
        device: DeviceState?,
        onboarding: (user: String, state: UserState?)?,
        ineligible: Bool = false
    ) -> String {
        // Out of scope is its own answer. Without it a Mac the profile
        // deliberately refuses reports "not started", which in a list of
        // hundreds is indistinguishable from one the package never reached.
        guard !ineligible else {
            return "provisioning: not applicable (requireADE)"
        }
        return [provisioningPhrase(device), onboardingPhrase(onboarding)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func provisioningPhrase(_ device: DeviceState?) -> String {
        guard let device else { return "provisioning: not started" }
        let terminal = device.items.values.filter { $0.outcome.isTerminal }
        let failed = device.items.values.filter { $0.outcome == .failed }
        if device.completedAt != nil {
            return "provisioning: complete (\(terminal.count)/\(device.items.count))"
        }
        if !failed.isEmpty {
            return "provisioning: failed (\(failed.count) failed, \(terminal.count)/\(device.items.count) finished)"
        }
        return "provisioning: in progress (\(terminal.count)/\(device.items.count))"
    }

    private static func onboardingPhrase(_ onboarding: (user: String, state: UserState?)?) -> String? {
        guard let onboarding else { return "onboarding: no console user" }
        guard let state = onboarding.state else {
            return "onboarding: not started (\(onboarding.user))"
        }
        if state.completedAt != nil {
            return "onboarding: complete (\(onboarding.user))"
        }
        let done = state.items.values.filter { $0.outcome.isTerminal }.count
        return "onboarding: in progress (\(onboarding.user), \(done)/\(state.items.count))"
    }

    private func printJSON(
        device: DeviceState?,
        onboarding: (user: String, state: UserState?)?,
        store: StateStore
    ) throws {
        struct Onboarding: Encodable {
            let user: String
            let complete: Bool
            let completedAt: Date?
            let items: [String: ItemRecord]
        }
        struct Snapshot: Encodable {
            let deviceComplete: Bool
            let deviceCompletedAt: Date?
            let lastRunAt: Date?
            let items: [String: ItemRecord]
            /// Absent while the console belongs to Setup Assistant or the
            /// login window — there is no user to report on yet.
            let onboarding: Onboarding?
        }
        let snapshot = Snapshot(
            deviceComplete: device?.completedAt != nil,
            deviceCompletedAt: device?.completedAt,
            lastRunAt: device?.lastRunAt,
            items: device?.items ?? [:],
            onboarding: onboarding.map { reported in
                Onboarding(
                    user: reported.user,
                    complete: reported.state?.completedAt != nil,
                    completedAt: reported.state?.completedAt,
                    items: reported.state?.items ?? [:]
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
    }
}

// MARK: - reset

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete onboarding state for testing. Requires root for device state."
    )

    @Flag(name: .customLong("device"), help: "Remove the device state and marker.")
    var device = false

    @Option(name: .customLong("user"), help: "Remove the named user's state (repeatable).")
    var users: [String] = []

    func validate() throws {
        guard device || !users.isEmpty else {
            throw ValidationError("Pass --device and/or --user <name>.")
        }
    }

    func run() throws {
        let store = StateStore()
        if device {
            guard getuid() == 0 else {
                print("reset --device must run as root")
                throw ArgumentParser.ExitCode(OnboardCore.ExitCode.notRoot.rawValue)
            }
            try store.reset()
            print("device state removed")
        }
        for user in users {
            let url = store.userStateURL(userName: user)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                print("user state removed: \(user)")
            } else {
                print("no state for user: \(user)")
            }
        }
    }
}

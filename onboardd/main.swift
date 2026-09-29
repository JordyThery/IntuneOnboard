import Foundation
import OnboardCLI
import OnboardCore
import os

// `run` (the default, used by launchd) is handled here; every other
// subcommand is handled by OnboardCLI.

let arguments = Array(CommandLine.arguments.dropFirst())
let subcommand = arguments.first ?? "run"

guard subcommand == "run" else {
    OnboardCommands.run(arguments: arguments)
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("onboardd: must run as root\n".utf8))
    OnboardLog.daemon.error("onboardd must run as root")
    exit(ExitCode.notRoot.rawValue)
}

OnboardLog.daemon.notice("onboardd starting, pid \(ProcessInfo.processInfo.processIdentifier)")

let coordinator = DaemonCoordinator()

// Start XPC first so the UI can connect while the daemon waits for configuration.
let xpcListener = XPCListener(coordinator: coordinator)
xpcListener.start()

let monitor = SessionMonitor(
    launcher: SetupAssistantLauncher(),
    isRunActive: { await coordinator.isRunActive() }
)
monitor.start()

Task { @MainActor in
    _ = await coordinator.run()
    // Waits for the UI to read the final state and for any retry in progress.
    exit(await coordinator.settledExitCode())
}

RunLoop.main.run()

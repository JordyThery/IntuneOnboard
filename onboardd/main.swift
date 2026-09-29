import Foundation
import OnboardCLI
import OnboardCore
import os

// onboardd entry point. `run` (the launchd daemon path, default) lives here
// because it owns session monitoring and the engine; every other subcommand —
// status, validate-config, reset — is handled by OnboardCLI via
// swift-argument-parser.

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

// XPC up first so a UI can always connect, even while waiting for config.
let xpcListener = XPCListener(coordinator: coordinator)
xpcListener.start()

// Watch the console and put the UI in front of whoever owns it — and keep it
// there for as long as the run has something to show.
let monitor = SessionMonitor(
    launcher: SetupAssistantLauncher(),
    isRunActive: { await coordinator.isRunActive() }
)
monitor.start()

// The run itself; the process exits with the engine's verdict. launchd does
// not relaunch on success (one-shot semantics).
Task { @MainActor in
    _ = await coordinator.run()
    // The grace before exiting lives in the coordinator: it gives the UI a
    // moment to pull the final snapshot, and — unlike a plain sleep here — it
    // holds the process open while a Try again that arrived over XPC is still
    // running the engine. Exiting killed that pass mid-item once.
    exit(await coordinator.settledExitCode())
}

RunLoop.main.run()

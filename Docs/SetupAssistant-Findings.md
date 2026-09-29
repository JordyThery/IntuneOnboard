# Setup Assistant integration

Technical notes on showing the provisioning window during Setup Assistant.

## Launch

- The daemon polls the console user (`SCDynamicStoreCopyConsoleUser`) every
  two seconds.
- When it is `_mbsetupuser`, the daemon runs
  `launchctl asuser <uid> /usr/bin/open -a "Intune Onboard.app" --args --mode setup-assistant`.
- The window appears once enrollment completes and Setup Assistant moves to
  its next pane. Enable **Await Final Configuration** so there is a pane to
  appear over.
- If the app exits while provisioning is running, the daemon relaunches it,
  at most three times per run.

## Window

- Level `screenSaver + 1` (1001) is sufficient. Override for testing with
  `--window-level <n>`.
- The window is `.titled` with a hidden titlebar, not `.borderless`: a
  borderless window cannot become key and would not receive ⌃⌥⌘Q or ⌘L.
- Setup Assistant draws its card inside a single full-screen window, so there
  is no card window to match. The provisioning window is 800×600, centred on
  the primary display.
- A separate borderless window on each display, just below the provisioning
  window, blocks clicks elsewhere. It sits below the menu bar, leaving
  Setup Assistant's accessibility options reachable.
- Geometry is recomputed when screen parameters change.

## Daemon

- The `onboardd` target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The
  XPC listener and service must be `nonisolated`: XPC calls them on its own
  queue, and the main-actor isolation check would otherwise crash the daemon
  on every connection.
- The daemon is started on demand through `MachServices` (no `KeepAlive`), so
  each XPC connection from the app can start a new instance. State on disk,
  not process memory, determines what an instance does.
- The LaunchDaemon uses `Program` with an absolute path. `BundleProgram` is
  resolved only for daemons registered with `SMAppService`, not for plists
  installed by a package.

## Logs

- Installomator writes progress to `/var/log/Installomator.log`, not to its
  standard output after the start banner; the log panel reads that file.
- MDM activity (`mdmclient`, `profiles`) is only in the unified log. The log
  panel export includes the last hour of it as `mdm-unified-log.txt`.
- Intune's Sidecar service delivers shell scripts and custom attributes.
  Sidecar errors in the Intune log can delay the custom attribute; they do not
  affect provisioning.

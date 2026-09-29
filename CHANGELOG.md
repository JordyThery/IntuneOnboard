# Changelog

## Unreleased

A code review of the process-lifetime paths, and the fixes it produced. No
schema changes; one behavioural note for `script` items by `path`.

- The daemon no longer exits while a **Try again** requested over XPC is
  still running the engine. It used to give the UI five seconds after its
  verdict and then exit unconditionally — and a retry accepted inside that
  window was killed mid-item, root work terminated abruptly and silently
  re-run by the next spawn.
- Subprocess stderr is drained while the child runs. A script writing more
  than the pipe's ~64 KB to stderr (one `set -x` away) used to block, never
  exit, and be reported as a timeout with its evidence truncated.
- A timeout now takes the process *tree*. Killing only the interpreter left
  its children — a hung download, an installer — running as root after the
  item was recorded failed.
- The three-attempt cap also stops an item whose attempts died mid-run
  (daemon killed, Mac rebooted). A `.running` record at the cap is recorded
  as the failure it was instead of re-executing on every spawn, forever.
- `script` items by `path` are staged: the file is verified through an open
  descriptor (root-owned, not group/world-writable, a regular file, no
  symlink) and the verified bytes are copied into a root-only 0700 directory
  and run from there — a swap between check and execution changes nothing.
  `$0` is therefore the staged copy, not the configured path.
- Installomator options may no longer contain a bare space (Installomator
  `eval`s each option, and `KEY=a b` runs `b` as a command); a value that
  needs spaces arrives quoted, which is now an accepted shape.
- A state file that exists but will not decode is quarantined as
  `<name>.corrupt` and logged, instead of silently reading as "no state" —
  which for `device.json` meant forgetting the completion marker and
  re-provisioning a finished Mac.
- The daemon's XPC listener refuses connections on a release build with no
  Team ID (a stripped or re-signed binary) instead of accepting anything.
- The kiosk's click-blocker covers every attached display, not just the
  first.
- Upgrades and `uninstall.sh` boot the login agent out of every user session,
  not only the console one — a fast-user-switched session used to keep the
  old binary running.
- The onboarding helpers run only from the app bundle; the silent fallback to
  `/usr/local/bin` (routinely user-writable under Homebrew) is gone.
- Log rotation settings from the profile now apply to the first provisioning
  run — the one that produces most of the log — not only to later spawns.
- Smaller: the relaunch check's `pgrep` pattern is escaped and anchored, and
  `reset --user` refuses names carrying path separators.

## 1.0.1

First public release.

Two stages, driven entirely by a configuration profile:

- **Provisioning** runs during Setup Assistant as root, before any user
  exists — Installomator labels, root scripts, waits, naming the Mac — in a
  full-screen window above Setup Assistant.
- **Onboarding** runs at first login as the signed-in user: wallpaper, Dock,
  default apps, "open this and sign in" steps, and demotion from admin to
  standard as the last act.

Supporting the above:

- `dryRun` renders a whole run and changes nothing, so a profile can be
  reviewed before it reaches a Mac.
- `--demo provisioning` / `--demo onboarding` run either stage on any Mac
  with no profile and no daemon, against an in-memory model.
- Status is re-derived from the system on every load, so steps are idempotent
  and a step un-completes if the user undoes it.
- An Intune custom attribute reports both stages in one line.
- Unknown keys in a profile are a hard error rather than a silent no-op.
- English, Dutch and French, following the Mac's language; text supplied in
  the profile carries its own translations.
- ⌘L opens a four-tab log panel with an export button — during Setup
  Assistant it is the only way to see anything, as there is no Terminal.

Requires macOS 15 or later, and ADE enrollment for the provisioning stage.

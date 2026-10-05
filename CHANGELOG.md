# Changelog

## 1.0.2

### Fixed

- A **Try again** started shortly after a run finished could be terminated
  mid-item when the daemon exited.
- Scripts writing more than 64 KB to stderr hung until their timeout.
- A timeout left the script's child processes running.
- Items interrupted mid-run (daemon killed, Mac restarted) were retried
  indefinitely; they now count toward the three-attempt limit.
- A corrupt state file was read as empty, which could re-provision a finished
  Mac. It is now moved aside as `<name>.corrupt` and logged.
- Log rotation settings were ignored on the first run.
- The Setup Assistant click blocker covered only the primary display.
- Upgrades and `uninstall.sh` left the login agent running in background user
  sessions.
- `onboardd reset --user` deleted a file that is never written, so it never
  reset anything. It now removes the user's `user.json`, the file `status`
  reads.
- With `windowPosition: focus`, the backdrop kept showing the previous
  wallpaper after the wallpaper step until the Dock restarted.

### Changed

- `script` items with a `path` are verified through an open file descriptor and
  run from a root-only copy. `$0` is the copy's path.
- Installomator options may not contain unquoted spaces. Quote values that need
  them: `LOGO="/Library/Application Support/logo.png"`.
- Release builds refuse XPC connections when the running binary has no Team ID.
- Onboarding helpers run only from the app bundle.
- `reset --user` rejects names containing path separators.

## 1.0.1

First public release.

- **Provisioning** during Setup Assistant: Installomator labels, scripts,
  waits and device naming, shown in a full-screen window.
- **Onboarding** at first login: wallpaper, Dock, default apps,
  open-and-sign-in steps, and demotion to a standard account.
- `dryRun` renders a complete run without changing the Mac.
- `--demo provisioning` and `--demo onboarding` run without a profile.
- Step status is re-derived from the system on every launch.
- Intune custom attribute reporting both stages.
- Unknown profile keys are reported as errors.
- English, Dutch and French.
- Log panel (⌘L) with export.

# Changelog

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

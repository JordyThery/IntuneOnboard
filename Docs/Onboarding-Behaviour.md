# onboarding — behavioural spec

What the onboarding actions must *do*. The behaviour was specified from a
1,800-line provisioning shell script this app replaces, so a few rules below
exist to stay bug-compatible with it; those are called out where they are not
self-evident. The profile keys are `Docs/Configuration.md`.

## Who runs what

The script runs as root (Intune) and drops into the user's session with
`launchctl asuser $uid sudo -u $user <tool>` for everything user-level. Our
onboarding app already **is** the user, so it calls the user-level tools
directly; only two operations go to the daemon over XPC:

| Operation | Side | Why |
|---|---|---|
| Wallpaper download → `/Library/Application Support/IntuneOnboard/` | daemon | root-owned destination |
| `demoteUser` (`dseditgroup`) | daemon | editing the admin group needs root |
| desktoppr, dockutil, utiluti, `open` | app (as the user) | they act on *this user's* session; running them from root needs the asuser+sudo dance and breaks TCC attribution |

## wallpaper

Two halves with different failure rules.

**Download (daemon, only when `source` is a URL).**
- `curl -fL`, connect timeout 20 s, overall 120 s → temp file in `/var/tmp`.
- If `sha256` is configured: verify before installing; mismatch = download
  failed. (Never guess a hash; omitted = no verification.)
- Install to the destination `root:wheel 0644`, creating the directory.
- **Failure is a real failure** — the item is `failed`, and the script
  additionally withholds the user's first-run marker ("User marker will not be
  written"). The run continues; nothing else is blocked.
- Timing note: the script downloads at the start of the user phase. We can do
  better — the daemon can pre-fetch during provisioning so the onboarding works
  offline and the apply step is instant.

**Apply (app, as the user).**
- Destination file absent → **skipped**, not failed ("no wallpaper configured
  locally" is a normal state).
- Idempotence by content hash: the applied file's SHA-256 is recorded in the
  user's state (`wallpaper.sha256` in the script; `UserState` for us). Same
  hash → **skipped** ("already applied and unchanged").
- Otherwise run `desktoppr <path>`; success records the new hash. desktoppr
  missing/unusable → **failed**, counted as an error.

## dock

All as the user, one pass:

1. `removeAll`/`dockAction: replace` → `dockutil --remove all --no-restart`.
2. Each configured item, in order:
   - Path does not exist → increment **skipped** and move on. This is why:
     it prevents question-mark Dock icons, and it is what makes listing apps
     that not every Mac has safe.
   - Else `dockutil --add <item> --no-restart`; success increments **added**,
     failure marks the whole item failed **but keeps adding the rest**.
3. One Dock restart at the end, after all edits (`--no-restart` per edit is
   what stops the Dock flickering N times). Script: `killall Dock`; ours
   honours `restartDock` and must kill only *this user's* Dock.
4. Status text carries the counts, verbatim pattern from the script:
   success `Klaar (X added, Y skipped)`, failure `Fout (X added, Y skipped)` —
   i.e. localized "Done"/"Error" + `(X added, Y skipped)`.

**Deliberate deviation:** the script auto-appends `/Applications/Privileges.app`
when `ALLOW_TEMP_ADMIN=1`. Per the approved design decisions, we do **not**
have implicit behaviour — Privileges is an explicit `bundleid:corp.sap.privileges`
entry in `dock.items`, and the skip-missing rule handles Macs without it.

## defaultApps

**Not in the script this app replaces** (utiluti is vendored but never invoked
there) — this kind exists because the build spec called for it:

- Read the current default first; anything already set as requested →
  **skipped** without prompting (auto-complete).
- Scalar value → confirmation UI; array → user picks one. A single value means
  the administrator has decided; a list means the choice is the user's, and
  the shape of the value is the whole signal.
- Apply with utiluti as the user — `utiluti url set <scheme> <bundle-id>`
  (the browser is the `http` scheme) and `utiluti type set <uti> <bundle-id>`.
  Taken from the vendored binary's own help after the first hardware run
  returned EX_USAGE (64) on a guessed `scheme set` spelling — when in doubt,
  ask the binary, not memory. macOS prompts for the browser and, from
  macOS 26.4, for every UTI change; the user refusing the prompt leaves the
  item incomplete and retryable, not failed.
- Runs strictly from the app, never via the daemon: the consent prompt is
  attributed to the responsible process, and root-spawned helpers get wrong or
  missing attribution.

## open

Also not behavioural in the script; per our config reference: launch the
target (app path / `bundleid:` / any-scheme URL) as the user. Completion:
`manual` means pressing the open button **is** completing the step — launching
is the act, and there is nothing to verify (a separate "mark as done" proved
redundant on hardware); `validatePath` completes only when the receipt path
appears, for the verifiable cases.

## demoteUser

Daemon-side, and **last in the run order** (script order: wallpaper → dock →
demote) — interactive steps happen while the user still has whatever rights
they came with, and demotion can't strand a half-finished run.

- `exclude` check first (**our addition**, approved decision #5 — the script
  demotes unconditionally): username listed → **skipped**.
- `dseditgroup -o checkmember -m <user> admin`; not a member → **skipped**
  ("not needed").
- Member → `dseditgroup -o edit -d <user> -t user admin`; failure = error.

## Completion marker and validation

The user's first-run marker is written only when **all three** hold:

1. A configured wallpaper download did not fail this run.
2. No new errors were counted during the user-phase steps.
3. Post-run validation passes.

Validation (script's `validate_user_first_run`, adapted):
- User state directory exists **and is owned by the user**.
- If a wallpaper file exists locally, the user's applied-hash record exists.
- If demotion is configured (and the user is not excluded), the user is **not**
  in the admin group — i.e. validation re-checks the outcome, not the exit code.
- Dock plist missing is a **warning only** (may not exist yet on a fresh
  profile).

No marker → the next launch runs the unfinished items again; the hash/current-
default/membership checks are what make re-running cheap and idempotent. They
also mean **status is re-derived from the system on every load** rather than
trusted from the record: a step un-completes if the user undoes it.

## Recurring runs

The script has `CHECK_WALLPAPER_EVERY_RUN` and `REAPPLY_DOCK_EVERY_RUN` flags
for its recurring-Intune mode. We get the same effect from status
re-derivation plus idempotent actions, so these are not config keys for now;
noted in case a "re-apply on every launch" request arrives later.

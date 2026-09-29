# Intune Onboard

A profile-driven macOS enrollment experience for Macs managed by Microsoft
Intune: a native SwiftUI app plus a root daemon replacing a swiftDialog-based
shell script.

## The two stages

These two words are the product's vocabulary, and they are used everywhere —
config keys, type names, log lines, documentation:

| Stage | When | Runs as | Does |
|---|---|---|---|
| **Provisioning** | During Setup Assistant, before any user exists | root (`onboardd`) | Installomator labels, root scripts, waits, naming the Mac |
| **Onboarding** | At first login, per user | the signed-in user | wallpaper, Dock, default apps, "open this" steps, admin demotion |

The profile mirrors them: a `provisioning` dictionary and an `onboarding`
dictionary, each with its own `items`.

## Layout

| Path | Contents |
|---|---|
| `IntuneOnboard/` | SwiftUI app target → `Intune Onboard.app` |
| `onboardd/` | Root daemon (command-line tool, embedded in the app bundle) |
| `Packages/OnboardCore/` | Local package: `OnboardCore` (models, no UI), `OnboardCLI` (the `onboardd` subcommands) and `OnboardUI` (views) |
| `LaunchServices/` | LaunchDaemon / LaunchAgent plists |
| `Scripts/` | `build-pkg.sh` and the pkg's pre/postinstall, plus `uninstall.sh`, `make-example-profile.sh`, `vendor-helpers.sh`, `verify-installomator.sh` |
| `Deploy/` | What an administrator uploads: the settings profile, the background-items profile, the Intune custom attribute |
| `Docs/` | `GettingStarted.md` (start here), `Configuration.md` (every profile key), `Operations.md` (deploying), `TestRunbook.md`, plus behaviour and Setup Assistant findings |
| `Vendor/` | Installomator, desktoppr, dockutil, utiluti — pinned, with checksums and licences |

## Building

Open `IntuneOnboard.xcodeproj` and build the `IntuneOnboard` scheme, or run
`Scripts/build-pkg.sh` for a pkg (unsigned locally; set `TEAM_ID`,
`DEVELOPER_ID_APP`, `DEVELOPER_ID_INSTALLER`, `NOTARY_PROFILE` for a
signed + notarized build).

Either stage runs without a device, against an in-memory Mac that nothing
real is changed on:

```sh
# provisioning, as a scripted timeline including a failure and a retry
open -a "Intune Onboard.app" --args --demo provisioning

# onboarding, fully interactive; --focus [blur] previews windowPosition: focus
open -a "Intune Onboard.app" --args --demo onboarding
```

## Deploying

**New to this? `Docs/GettingStarted.md`** walks from "watch it run on your own
Mac" to a real enrollment in three steps, with nothing at risk until the last
one.

`Docs/Operations.md` covers what to upload and in what order. In short: the
settings profile first, then the package, then the background-items profile
and the custom attribute.

The interface is English, Dutch and French, following the Mac's language.
Text you supply in the profile carries its own translations — see the
Languages section of `Docs/Configuration.md`.

## Status

Released and running in production. `CHANGELOG.md` records what shipped.

Two behaviours are implemented and unit-tested but have not been exercised on
hardware, and are worth knowing about before a wide rollout: expiry of the
ten-minute wait for a late configuration profile, and behaviour across
multiple displays with fast user switching. Provisioning-only and
onboarding-only deployments (omitting either dictionary from the profile)
work by design and are unit-tested, but have likewise not been run on a
device.

Issues and pull requests are welcome. If you are reporting a problem from a
real enrollment, the export from the ⌘L log panel is the most useful thing to
attach.

## Acknowledgements

Intune Onboard stands on other people's work, and would have been a much
poorer tool without it.

**Inspiration.** The shape of this product — a card that narrates provisioning
during Setup Assistant, and a per-user checklist at first login — follows the
path cut by **Jamf Setup Manager** and **Jamf Setup Checklist**. They
demonstrated that enrollment does not have to be a blank screen, and they set
the bar this was built to reach for Intune-managed fleets. Intune Onboard is
an independent implementation and shares no code with either, but the debt for
the idea is theirs and worth saying plainly.

**Bundled tools.** Four command-line tools do a great deal of the actual work.
All four are used unmodified, under the Apache License 2.0, with their licences
shipped inside the app bundle:

| Tool | Upstream | Pinned | What it does here |
|---|---|---|---|
| **Installomator** | [Installomator/Installomator](https://github.com/Installomator/Installomator) | `fb2b233` | Installs every app a provisioning `installomator` item names |
| **dockutil** | [kcrawford/dockutil](https://github.com/kcrawford/dockutil) | 3.1.3 | Reads and rewrites the user's Dock |
| **desktoppr** | [scriptingosx/desktoppr](https://github.com/scriptingosx/desktoppr) | v0.5 | Sets the wallpaper on every display |
| **utiluti** | [scriptingosx/utiluti](https://github.com/scriptingosx/utiluti) | v1.5 | Sets default browser, mail client and per-UTI handlers |

Installomator in particular is the reason app installation is a one-line
profile entry rather than a per-app scripting problem. It is pinned by
checksum to a reviewed snapshot (`Vendor/Installomator/PINNED_SHA256`), so
refreshing it is a deliberate, reviewable change rather than silent drift.

## Licence

MIT — see `LICENSE`. The four vendored tools remain under Apache-2.0; their
licences ship inside the app bundle and are listed at the end of `LICENSE`.

# Intune Onboard

Profile-driven enrollment for Macs managed by Microsoft Intune: a SwiftUI app
and a root daemon, configured by a single configuration profile.

| Stage | When | Runs as | Does |
|---|---|---|---|
| **Provisioning** | During Setup Assistant | root (`onboardd`) | Installomator labels, scripts, waits, device naming |
| **Onboarding** | At first login | the signed-in user | Wallpaper, Dock, default apps, open-and-sign-in steps, admin demotion |

The profile has a `provisioning` and an `onboarding` dictionary; either may be
omitted.

## Requirements

- macOS 15 or later.
- Automated Device Enrollment for the provisioning stage.
- Settings delivered as a device-assigned **Custom** configuration profile.

## Documentation

| Document | Contents |
|---|---|
| [`Docs/GettingStarted.md`](Docs/GettingStarted.md) | First deployment, step by step |
| [`Docs/Configuration.md`](Docs/Configuration.md) | Every profile key |
| [`Docs/Operations.md`](Docs/Operations.md) | What to deploy, status reporting, troubleshooting |
| [`Deploy/`](Deploy/) | Example profiles, background-items profile, Intune custom attribute |

## Trying it

Both stages run without a profile or daemon, against an in-memory Mac:

```sh
open -a "Intune Onboard.app" --args --demo provisioning
open -a "Intune Onboard.app" --args --demo onboarding
```

## Building

Open `IntuneOnboard.xcodeproj` and build the `IntuneOnboard` scheme, or run
`Scripts/build-pkg.sh` for an installer package. Set `TEAM_ID`,
`DEVELOPER_ID_APP`, `DEVELOPER_ID_INSTALLER` and `NOTARY_PROFILE` for a signed,
notarized build. See [`Docs/TestRunbook.md`](Docs/TestRunbook.md).

| Path | Contents |
|---|---|
| `IntuneOnboard/` | App target |
| `onboardd/` | Root daemon, embedded in the app bundle |
| `Packages/OnboardCore/` | `OnboardCore` (logic), `OnboardCLI` (`onboardd` subcommands), `OnboardUI` (views) |
| `LaunchServices/` | LaunchDaemon and LaunchAgent |
| `Scripts/` | Packaging, uninstall and vendoring scripts |
| `Vendor/` | Bundled tools, pinned by checksum |

## Status

1.0.1 is the current release. It has been tested extensively on hardware in a
single tenant but has not yet been used in a production rollout; pilot it
before deploying fleet-wide. Unreleased changes are listed in
[`CHANGELOG.md`](CHANGELOG.md).

Known limitations:

- Not yet verified on hardware: expiry of the ten-minute configuration wait,
  a second display during Setup Assistant, fast user switching while the
  provisioning window is shown, and onboarding-only profiles.
- `validate-config` reports `OK — 0 items` for a wrapped `.mobileconfig`;
  validate the bare `.plist` instead.

Profile scripts run as root. Configuration is read only from managed
preferences, and the app and daemon verify each other's code signature. The
code has had no external security review.

Issues and pull requests are welcome. For enrollment problems, attach the
export from the log panel (⌘L).

## Acknowledgements

Inspired by **Jamf Setup Manager** and **Jamf Setup Checklist**. Intune Onboard
is an independent implementation and shares no code with either.

Bundled, unmodified, under the Apache License 2.0:

| Tool | Upstream | Version | Used for |
|---|---|---|---|
| Installomator | [Installomator/Installomator](https://github.com/Installomator/Installomator) | `fb2b233` | App installation |
| dockutil | [kcrawford/dockutil](https://github.com/kcrawford/dockutil) | 3.1.3 | Dock |
| desktoppr | [scriptingosx/desktoppr](https://github.com/scriptingosx/desktoppr) | v0.5 | Wallpaper |
| utiluti | [scriptingosx/utiluti](https://github.com/scriptingosx/utiluti) | v1.5 | Default apps |

## Licence

MIT. See [`LICENSE`](LICENSE); bundled tools retain their own licences.

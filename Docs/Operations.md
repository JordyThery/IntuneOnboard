# Operations

## Installed files

| Path | Contents |
|---|---|
| `/Applications/Utilities/Intune Onboard.app` | App, daemon (`Contents/MacOS/onboardd`) and bundled tools |
| `/Library/LaunchDaemons/be.jordythery.intuneonboard.daemon.plist` | Daemon; runs provisioning |
| `/Library/LaunchAgents/be.jordythery.intuneonboard.agent.plist` | Agent; runs onboarding at login |
| `/Library/Application Support/IntuneOnboard/` | Device state and downloaded wallpapers |
| `~/Library/Application Support/IntuneOnboard/state/user.json` | Onboarding state per user |
| `/var/log/IntuneOnboard/` | `onboard.log`, `onboard-installomator.log` |

## Deploying in Intune

Assign everything to the same **device** group, in this order.

1. **Settings profile** (required). `be.jordythery.intuneonboard.mobileconfig`
   as Devices → Configuration → macOS → Templates → **Custom**. The Preference
   file template rejects it (`-2016341103`), and user-assigned profiles are not
   read.
2. **Package** (required). `IntuneOnboard-<version>.pkg` as a line-of-business
   app, assignment **required**. Intune redeploys when the build number
   changes.
3. **Background items profile** (recommended).
   `managed-login-items.mobileconfig` as a Custom profile. Without it, macOS
   shows "Background Items Added" and lets the user disable the agent.
4. **Custom attribute** (recommended). `custom-attribute-onboard-status.sh`
   under Devices → Scripts and remediations → macOS custom attributes. Type
   **String**; do **not** run as the signed-in user.

If the package arrives before the profile, the app waits ten minutes for it,
then retries at the next login.

## Status reporting

The custom attribute reports both stages:

```
provisioning: complete (4/4) · onboarding: in progress (jordy, 3/8)
provisioning: failed (1 failed, 4/4 finished) · onboarding: no console user
provisioning: not applicable (requireADE)
not installed
```

| Value | Meaning |
|---|---|
| `not applicable (requireADE)` | `requireADE` is set and the Mac was not enrolled through ADE; nothing runs. |
| `not installed` | The package is not installed. |
| `onboarding: not started` | Common right after enrollment; Intune reports the value from its last script run. |

On a Mac:

```sh
ONBOARDD="/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"
sudo "$ONBOARDD" status          # the attribute's line
sudo "$ONBOARDD" status --json   # per-item detail
```

## Logs

Press **⌘L** in the app for the log panel. It has tabs for Intune Onboard,
Installomator, the macOS installer and Intune, and **Export…** copies them, with
recent MDM log entries, to `/Users/Shared`. During Setup Assistant it is the
only way to view logs.

Script output is logged line by line, prefixed with the item id:

```
item rosetta: starting (attempt 1)
[rosetta] status: Rosetta 2 already installed
item rosetta: success
```

## Running again

```sh
sudo "$ONBOARDD" reset --device                                  # provisioning
rm ~/Library/Application\ Support/IntuneOnboard/state/user.json  # onboarding, current user
```

Steps already in their desired state complete without being repeated.

## Upgrading

Deploy the new package. The installer restarts the daemon and agent without a
reboot. State is kept: completed provisioning and onboarding do not run again.

## Uninstalling

```sh
sudo sh uninstall.sh
```

Removes the app, the launchd jobs, all state and logs.

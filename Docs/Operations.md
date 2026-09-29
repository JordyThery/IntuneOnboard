# Operations

Deploying and running Intune Onboard in a tenant. For the profile's keys see
`Configuration.md`; for a first walkthrough see `GettingStarted.md`.

## What lands on a Mac

| Path | What |
|---|---|
| `/Applications/Utilities/Intune Onboard.app` | The app, with `onboardd` and the bundled helpers inside it |
| `/Library/LaunchDaemons/be.jordythery.intuneonboard.daemon.plist` | The root daemon: runs provisioning |
| `/Library/LaunchAgents/be.jordythery.intuneonboard.agent.plist` | Per-user agent: runs onboarding at login |
| `/Library/Application Support/IntuneOnboard/` | Device state, progress, wallpaper cache (root-owned) |
| `~/Library/Application Support/IntuneOnboard/state/user.json` | One user's onboarding state |
| `/var/log/IntuneOnboard/` | `onboard.log`, `onboard-installomator.log` |

## What to deploy in Intune

Four things, in this order. The first two are required; the rest make it
supportable.

### 1. The settings profile — required

`be.jordythery.intuneonboard.mobileconfig` as **Devices → Configuration →
macOS → Templates → Custom**, assigned to a **device** group.

Device-scoped is not a detail: a user-assigned profile lands in
`/Library/Managed Preferences/<user>/`, which the root daemon never reads and
which does not exist during Setup Assistant at all. The **Preference file**
template is not an alternative: it rejects a wrapped profile with error
`-2016341103`.

Deploy this **before** the package. If the profile is late the app shows
"Waiting for configuration…" and polls for ten minutes. A profile later
than that is still not fatal: the daemon is brought back by the next XPC
connection, so the following login tries again.

### 2. The package — required

`IntuneOnboard-<version>.pkg` as a **line-of-business app**, device
assignment, **required**.

Intune redeploys only when the package's build number changes, so each new
version reaches an enrolled Mac on its own.

### 3. The background items profile — recommended

`managed-login-items.mobileconfig`, again a Custom profile on the same device
group.

Without it macOS tells the user "Background Items Added" during enrollment and
offers them a switch in **Login Items & Extensions** that turns onboarding
off. With it, the daemon and the agent are approved and the switch is gone.

One `LabelPrefix` rule covers both launchd jobs. Requires
user-approved MDM, which an ADE enrollment always is. A `TeamIdentifier` rule
would be an alternative, but broader: it approves anything signed with the
same Developer ID.

### 4. The custom attribute — recommended

`custom-attribute-onboard-status.sh` under **Devices → Scripts and
remediations → macOS custom attributes**:

- Attribute type: **String**
- Run script as signed-in user: **No** — it has to be root to read the device
  state

It reports both stages in one line:

```
provisioning: complete (4/4) · onboarding: in progress (jordy, 3/8)
provisioning: failed (1 failed, 4/4 finished) · onboarding: no console user
provisioning: not applicable (requireADE)
not installed
```

Both halves are there on purpose. A Mac whose provisioning finished is not a
Mac that is set up: the person in front of it may still have every onboarding
step ahead of them, and an attribute reporting only the device would call that
Mac done.

`not applicable (requireADE)` means the profile deliberately refuses this
Mac: it was not enrolled through ADE, so neither stage runs and the person
using it is shown nothing. Filter on it to find Macs assigned a profile that
does not apply to them.

`not installed` is the value to filter on when looking for Macs the package
has not reached.

**The value is a snapshot, not a live reading.** Intune runs the script on its
own schedule and stores whatever it printed, so a Mac enrolled minutes ago
typically reports

```
provisioning: complete (4/4) · onboarding: not started (jordy)
```

— correct at the moment it ran, and stale by the time you read it if the user
has since worked through the steps. It catches up at the next run. Read a
single `not started` as "no news yet" rather than as a problem, and judge
onboarding across a fleet rather than on one freshly enrolled Mac.

## Reading the state on a Mac

```sh
# The same line the custom attribute reports
sudo "/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd" status

# Everything, including per-item records for both stages
sudo "/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd" status --json
```

In front of a Mac mid-run, **⌘L** opens the log panel — four tabs, named for
what each shows: Intune Onboard, Installomator, the macOS installer and
Intune — and an **Export…** button that copies
them to `/Users/Shared` together with the MDM entries from the unified log.
During Setup Assistant that panel is the only way to see anything: there is no
Terminal and no Console.

The first tab carries every item's start and outcome, and a `script` item's
own output line by line, tagged with the item id:

```
item rosetta: starting
[rosetta] status: Rosetta 2 already installed
item rosetta: success
[failing-step] stderr: deliberate failure to exercise the retry flow
item failing-step: failed — exit 7 — deliberate failure to exercise the retry flow
```

A failed run does not end there. At the next login the provisioning card
comes back in front of onboarding, carrying **Try again**.

## Re-running without a wipe

```sh
# Onboarding again, for the current user
rm ~/Library/Application\ Support/IntuneOnboard/state/user.json

# Provisioning again (root)
sudo "/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd" reset --device
```

Both stages re-derive what they can from the Mac itself, so a step whose end
state already holds completes without doing the work again.

## Upgrading

Upload the new pkg over the old one. Its postinstall re-bootstraps the daemon
and the agent, so a running Mac picks the new build up without a reboot.

State survives an upgrade by design: a Mac that finished provisioning does not
do it again, and a user who finished onboarding is not asked twice.

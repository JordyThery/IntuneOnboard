# Hardware test runbook (M0 + M2 + M3 acceptance)

What this run validates: the Setup Assistant launch path, window level, session
survival across Await Final Configuration, a real end-to-end Installomator run,
and — from M3 — the real provisioning UI over Setup Assistant.

Try the UI without a device first: `--demo provisioning` runs a scripted
timeline including a failure and a working retry.

```sh
open -a "Intune Onboard.app" --args --demo provisioning --launched-by manual-demo
```

## One-time signing prep (dev Mac)

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
security find-identity -v | grep "Developer ID Installer"
xcrun notarytool store-credentials intuneonboard-notary
```

`store-credentials` needs an Apple ID and an app-specific password
(appleid.apple.com → Sign-In and Security), so it cannot be scripted for you.

**Being signed into Xcode does not cover this.** Xcode's Organizer notarizes
using its own accounts, but `xcrun notarytool` — which the build script uses —
has a separate credential store and never reads them. That question has come
up more than once.

MDM-installed packages are not gatekept, so an unnotarized pkg deploys through
Intune perfectly well. A notarized one also installs **by hand** without a
warning, which is what matters for a technician testing on a bench.

Every build ends by saying what it actually produced:

```
==> Verifying
    stapled: yes
    …: accepted
```

`stapled: no` with `source=Unnotarized Developer ID` means the pkg is signed
but not notarized: fine for Intune, a Gatekeeper prompt by hand. The build
script prints the notary log when Apple rejects a submission, which is the
only place the reason appears.

An already-built pkg can be notarized in place, without rebuilding:

```sh
xcrun notarytool submit dist/IntuneOnboard-<version>.pkg \
    --keychain-profile intuneonboard-notary --wait
xcrun stapler staple dist/IntuneOnboard-<version>.pkg
```

## 1. Build the pkg (dev Mac)

```sh
cd ~/Developer/IntuneOnboard && git pull
TEAM_ID="<YOURTEAMID>" \
DEVELOPER_ID_APP="Developer ID Application: <name> (<TEAMID>)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: <name> (<TEAMID>)" \
NOTARY_PROFILE="intuneonboard-notary" \
Scripts/build-pkg.sh
# → dist/IntuneOnboard-<version>.pkg (signed, notarized, stapled)
```

## 2. Intune setup (once)

1. **App:** Apps → macOS → Add → *macOS app (PKG)* → upload → Required,
   **device** context → assign to the test device group.
2. **Config:** Devices → macOS → Configuration profiles → *Templates →
   Preference file* → domain `be.jordythery.intuneonboard` → upload
   `Deploy/be.jordythery.intuneonboard.plist` → assign to the same group.
   (`plutil -lint` any local edits first.)
3. **ADE:** enrollment profile for the test serial has **Await Final
   Configuration** enabled.

## 3. Enroll and observe

1. Erase / wipe → boot → network in Setup Assistant → ADE enrollment.
2. Watch for the provisioning window; note:
   - appeared? at which Setup Assistant step? how long after enrollment?
   - full screen? above or below Setup Assistant chrome?
   - does it say "Waiting for the configuration profile…"? That means the
     profile has not landed — check step 3 below before anything else.
   - do the item rows advance, and does the progress bar track them?
   - behavior at the moment Await Final Configuration released the device.
   - ⌘Q should do nothing (M3). Try it.

   **If you need out: ⌃⌥⌘Q.** The kiosk has no other exit — during Setup
   Assistant there is no Dock, no Force Quit and no Terminal. The shortcut
   tells the daemon to stop relaunching the window and quits; provisioning
   keeps running in the background. If the app has been killed some other way,
   the daemon restores it at most three times per run and then leaves it
   alone, so the Mac can never be trapped.

   **⌘L opens the log window** — four tabs, a Summarize toggle and an Export
   button that copies everything to
   `/Users/Shared/IntuneOnboardLogs-<timestamp>`. That export is the fastest
   way to get artifacts off a Mac still in Setup Assistant.

   | Tab | File | Notes |
   |---|---|---|
   | Onboarding | `/var/log/IntuneOnboard/onboard.log` | Ours. Already terse, so Summarize is disabled. |
   | Installomator | `/var/log/Installomator.log` | Its own log, not our captured stdout — it reassigns stdout after its banner, so this is the only place download progress appears. |
   | Installer | `/var/log/install.log` | Two families of benign line are filtered out of the *panel* (`IFJS: Package Authoring Error` from Microsoft's packages, `_buildInstallPlanReturningError:` from `installd`). Both say "Error" and neither is one. |
   | Intune | newest `.log` under `/Library/Logs/Microsoft/Intune` | Empty until Intune installs its agent, which happens partway through enrollment — so "nothing here yet" early in Phase A is the expected state. Company Portal's user-level log is picked up after first login. |

   **Enrollment's own traffic is not in any of those files.** `mdmclient` and
   `profiles` log to the unified log, so Export also writes
   `mdm-unified-log.txt` — the last hour of MDM activity, which is where
   "Intune says it pushed the profile, the Mac disagrees" gets settled. If
   `log show` is refused for the setup user, the file contains that error
   instead, which is itself the answer.

   Last resort, if the shortcut somehow doesn't land: `⌃⌥⌘T` opens a root
   Terminal in Setup Assistant —

   ```sh
   launchctl bootout system/be.jordythery.intuneonboard.daemon
   pkill -f "Intune Onboard.app/Contents/MacOS/Intune Onboard"
   ```
3. **Confirm the profile actually arrived** — a run without it sits in
   `waitingForConfig` forever and Phase A never starts:

   ```sh
   ls -l "/Library/Managed Preferences/be.jordythery.intuneonboard.plist"
   sudo profiles show -type configuration | grep -i intuneonboard
   ```

4. Finish Setup Assistant and log in. If Phase A is still running you get the
   card again as a "please wait" screen; if it has finished, **nothing should
   appear** — the user session is Phase B's (M4), not Phase A's. Give Phase A
   time regardless: M365 (~3 GB), Edge, Company Portal, TeamViewer QS.

## 4. Verify on the device

```sh
ONBOARDD="/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"
sudo "$ONBOARDD" status          # expect: provisioning: complete (4/4)
sudo "$ONBOARDD" status --json
ls /Applications | grep -Ei "outlook|edge|company|teamviewer"
launchctl print system/be.jordythery.intuneonboard.daemon | head -20
cat "/Library/Application Support/IntuneOnboard/progress.json"
```

## 5. Collect artifacts

**Wait for the run to finish first.** `progress.json` always shows the latest
state, and `onboard.log` says nothing between "run starting" and the final
verdict — so artifacts taken mid-run look identical for a healthy run and a
stuck one. A run is over when either of these is true:

```sh
sudo "$ONBOARDD" status | grep -q complete   # marker written, or
# more than 10 minutes have passed since "run starting"
```

```sh
mkdir ~/Desktop/onboard-artifacts
sudo cp /var/log/IntuneOnboard/*.log ~/Desktop/onboard-artifacts/
sudo cp -R "/Library/Application Support/IntuneOnboard" ~/Desktop/onboard-artifacts/state
sudo "$ONBOARDD" status --json > ~/Desktop/onboard-artifacts/status.json
ls -l "/Library/Managed Preferences/be.jordythery.intuneonboard.plist" \
    > ~/Desktop/onboard-artifacts/managed-prefs.txt 2>&1
```

The unified log is the **only** place the session and launch lines
(`console user:`, `launching … into uid`, `window:`) appear — `onboard.log`
carries the coordinator's own messages only. Capture it for the whole boot
rather than a time window, and check it is not empty before packing up:

```sh
log show --last boot --predicate 'subsystem == "be.jordythery.intuneonboard"' --info \
    > ~/Desktop/onboard-artifacts/unified.log
wc -l ~/Desktop/onboard-artifacts/unified.log   # a header-only file means the
                                                # predicate matched nothing
```

AirDrop the folder + observation notes back; results land in
`SetupAssistant-Findings.md`.

## 6. Re-run without a full wipe

```sh
sudo "$ONBOARDD" reset --device
sudo launchctl kickstart -k system/be.jordythery.intuneonboard.daemon
```

If the window did not appear over Setup Assistant: enable Remote Login
(`sudo systemsetup -setremotelogin on`) for same-boot experiments with
`--window-level` (values in `SetupAssistant-Findings.md`), keeping in mind an
erase-and-enroll cycle resets it. If no level works, first-login mode becomes
the default path per the spec.

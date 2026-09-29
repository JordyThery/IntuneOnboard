# Building and testing

## Signing prerequisites

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
security find-identity -v | grep "Developer ID Installer"
xcrun notarytool store-credentials intuneonboard-notary
```

`store-credentials` needs an Apple ID and an app-specific password. Xcode's
account sign-in is not used by `notarytool`.

## Building

```sh
TEAM_ID="<TEAMID>" \
DEVELOPER_ID_APP="Developer ID Application: <name> (<TEAMID>)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: <name> (<TEAMID>)" \
NOTARY_PROFILE="intuneonboard-notary" \
Scripts/build-pkg.sh
```

Output: `dist/IntuneOnboard-<version>.pkg`. The script deletes `build/` and
`dist/` before starting. It ends by reporting whether the package is stapled
and accepted by Gatekeeper. Without the signing variables it builds an
unsigned package.

To notarize an existing package:

```sh
xcrun notarytool submit dist/IntuneOnboard-<version>.pkg \
    --keychain-profile intuneonboard-notary --wait
xcrun stapler staple dist/IntuneOnboard-<version>.pkg
```

Unit tests:

```sh
cd Packages/OnboardCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Testing on a device

1. Upload the package as a required line-of-business app and the settings as
   a Custom profile, both to a device group.
2. Enable **Await Final Configuration** in the ADE enrollment profile.
3. Erase the Mac and enroll it. The provisioning window appears once
   enrollment completes.

During Setup Assistant:

| Keys | Action |
|---|---|
| ⌘L | Log panel. **Export…** writes all logs to `/Users/Shared/IntuneOnboardLogs-<timestamp>`. |
| ⌃⌥⌘Q | Quit the window. Provisioning continues. |
| Space | Serial number barcode. |
| ⌃⌥⌘T | Root Terminal (macOS), if the window cannot be quit. |

If the window shows "Waiting for the configuration profile…", check that the
profile arrived:

```sh
ls -l "/Library/Managed Preferences/be.jordythery.intuneonboard.plist"
sudo profiles show -type configuration | grep -i intuneonboard
```

## Collecting diagnostics

```sh
ONBOARDD="/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd"
mkdir ~/Desktop/onboard
sudo cp /var/log/IntuneOnboard/*.log ~/Desktop/onboard/
sudo "$ONBOARDD" status --json > ~/Desktop/onboard/status.json
log show --last boot --info \
    --predicate 'subsystem == "be.jordythery.intuneonboard"' \
    > ~/Desktop/onboard/unified.log
```

Session and window events are only in the unified log.

## Re-running

```sh
sudo "$ONBOARDD" reset --device
sudo launchctl kickstart -k system/be.jordythery.intuneonboard.daemon
```

To test settings without Intune on a Mac that is not MDM-enrolled, copy a bare
settings plist to `/Library/Managed Preferences/be.jordythery.intuneonboard.plist`
(owner root:wheel, mode 644).

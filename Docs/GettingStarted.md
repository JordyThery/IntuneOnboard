# Getting started

Three steps: see it run, validate your configuration in dry run, then enroll a
Mac. Only the last step changes anything.

## 1. Run the demo

Install `IntuneOnboard-<version>.pkg`, then:

```sh
open -a "Intune Onboard.app" --args --demo provisioning
open -a "Intune Onboard.app" --args --demo onboarding
```

The provisioning demo includes a failing item. Press **⌘L** for the log
panel, which is the only log view available during Setup Assistant. The
onboarding demo is interactive and applies nothing.

## 2. Configure in dry run

This needs one Mac already enrolled in your tenant. With `dryRun` set, the
app renders every step and changes nothing.

### Create the settings

Save as `my-settings.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>dryRun</key>
	<true/>
	<key>organization</key>
	<dict>
		<key>name</key>
		<string>Contoso</string>
		<key>accentColor</key>
		<string>#0F6CBD</string>
		<key>supportText</key>
		<string>IT service desk · +32 (0)3 123 45 67</string>
	</dict>
	<key>provisioning</key>
	<dict>
		<key>items</key>
		<array>
			<dict>
				<key>id</key>
				<string>edge</string>
				<key>kind</key>
				<string>installomator</string>
				<key>label</key>
				<string>microsoftedge</string>
				<key>title</key>
				<string>Microsoft Edge</string>
			</dict>
		</array>
	</dict>
	<key>onboarding</key>
	<dict>
		<key>items</key>
		<array>
			<dict>
				<key>id</key>
				<string>welcome</string>
				<key>kind</key>
				<string>message</string>
				<key>title</key>
				<string>Welcome to your new Mac</string>
				<key>subtitle</key>
				<string>A few quick steps and your Mac is ready.</string>
				<key>icon</key>
				<string>symbol:hand.wave</string>
			</dict>
			<dict>
				<key>id</key>
				<string>dock</string>
				<key>kind</key>
				<string>dock</string>
				<key>title</key>
				<string>Dock</string>
				<key>subtitle</key>
				<string>We recommend adding these apps.</string>
				<key>dockStrategy</key>
				<string>add</string>
				<key>items</key>
				<array>
					<string>/Applications/Microsoft Edge.app</string>
				</array>
			</dict>
		</array>
	</dict>
</dict>
</plist>
```

Replace the organization values. `organization.name` is the only required
key. Unknown keys cause the whole profile to be rejected, so misspellings are
reported rather than ignored.

### Validate

`validate-config` only reads root-owned files:

```sh
sudo cp my-settings.plist /tmp/check.plist
sudo chown root:wheel /tmp/check.plist
sudo chmod 644 /tmp/check.plist
sudo "/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd" \
    validate-config --path /tmp/check.plist
```

Expected output:

```
OK — schemaVersion 1, 1 provisioning item(s), 2 onboarding item(s)
```

Errors name the exact key:

```
configuration invalid:
  - config.onboarding.items[1].dockStrategie: unknown key — nothing in this
    build reads it here (misspelled, or from an older schema?)
```

Validate the `.plist`, not the `.mobileconfig`: a wrapped profile reports
`0 provisioning item(s), 0 onboarding item(s)`.

### Wrap as a profile

Save as `wrap.py` and run
`python3 wrap.py my-settings.plist my-profile.mobileconfig`:

```python
import plistlib, sys, uuid
settings = plistlib.load(open(sys.argv[1], "rb"))
domain = "be.jordythery.intuneonboard"
payload = dict(settings, PayloadType=domain,
               PayloadIdentifier=f"{domain}.settings",
               PayloadUUID=str(uuid.uuid4()), PayloadVersion=1,
               PayloadDisplayName="Intune Onboard settings")
plistlib.dump({"PayloadContent": [payload], "PayloadType": "Configuration",
               "PayloadIdentifier": f"{domain}.profile",
               "PayloadUUID": str(uuid.uuid4()), "PayloadScope": "System",
               "PayloadVersion": 1,
               "PayloadDisplayName": "Intune Onboard"},
              open(sys.argv[2], "wb"))
```

Edit the `.plist` and re-wrap; do not edit the `.mobileconfig` directly.

### Upload

Devices → Configuration → Create → New policy → macOS → Templates →
**Custom**. Upload `my-profile.mobileconfig` and assign it to a **device**
group.

- The Preference file template rejects wrapped profiles (`-2016341103`).
- User-assigned profiles are not read.

### Check

Once the profile appears in System Settings → General → Device Management,
log out and back in. The onboarding window shows your branding and a
**DRY RUN** badge. It reappears at every login until `dryRun` is removed.

## 3. Enroll a Mac

Provisioning runs during Setup Assistant, so this step needs a Mac you can
erase.

1. Remove `dryRun`, re-wrap and re-upload the profile.
2. Upload the package: Apps → macOS → Line-of-business app, **required**, same
   device group.
3. Upload `managed-login-items.mobileconfig` as a Custom profile on the same
   group, so users cannot disable the background items.
4. Optional: add `custom-attribute-onboard-status.sh` under Devices → Scripts
   and remediations → macOS custom attributes (String, not run as signed-in
   user).

Deploy the settings profile before the package. Without it, the app waits ten
minutes for configuration and then retries at the next login.

Erase and enroll the Mac. Press **⌘L** during Setup Assistant to follow the
log.

See [`Operations.md`](Operations.md) for the full deployment reference.

## Troubleshooting

| Symptom | Cause |
|---|---|
| No window at all | `requireADE` is on and the Mac was not enrolled through ADE. `onboardd status` reports `not applicable (requireADE)`. |
| "Waiting for the configuration profile…" | The profile has not arrived, or is assigned to a user group. |
| Upload error `-2016341103` | The Preference file template was used; use Custom. |
| "Configuration invalid" | A misspelled or outdated key; the message gives its path. |
| Provisioning does not run again | It already completed. Run `sudo onboardd reset --device` to repeat it. |
| Steps succeed but nothing changes | `dryRun` is still set. |
| `validate-config` reports 0 items | The `.mobileconfig` was validated instead of the `.plist`. |
| A Dock app was not added | It is not installed; missing apps are skipped. |
| A failed item did not stop provisioning | It is not `required`. Failed items are retried up to three times, then offered with **Try again** at next login. |

```sh
sudo onboardd status
sudo cat /var/log/IntuneOnboard/onboard.log
```

`onboardd` is at
`/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd`.

## Starting over

```sh
sudo onboardd reset --device                                     # provisioning
rm ~/Library/Application\ Support/IntuneOnboard/state/user.json  # onboarding, current user
sudo sh uninstall.sh                                             # everything
```

Steps already in their desired state complete without being repeated.

# Getting started with Intune Onboard

**Who this is for:** you can find your way around the Intune admin center —
configuration profiles, device groups, line-of-business apps — but you have
never deployed this product before. No macOS scripting knowledge assumed.

**How long:** step 1 takes five minutes. Step 2 takes half an hour. Step 3
needs a Mac you are willing to erase.

The order is deliberate. Step 1 shows the product with nothing at risk, step 2
gets your own configuration working without changing anything on a real Mac,
and only step 3 touches a Mac for real. If something breaks you will know
which of the three broke — which is the hard part when it is all done at once.

---

## What it does

Two separate stages, at two different moments. They are the product's whole
vocabulary, so it is worth thirty seconds:

| Stage | When | Who it runs as | Typical work |
|---|---|---|---|
| **Provisioning** | During Setup Assistant, before anyone has logged in | root, unattended | Install apps, run scripts, name the Mac |
| **Onboarding** | At first login, once per user | the person who just logged in | Wallpaper, Dock, default browser and mail, making them a standard user |

One configuration profile drives both: a `provisioning` section and an
`onboarding` section, each with a list of `items`.

<!-- Screenshot slot 1: provisioning over Setup Assistant. Best single image
     in the whole guide — it is the thing people cannot picture. -->

---

## Step 1 — Watch it run on your own Mac

Five minutes, on the Mac you are reading this on. **Nothing is changed** —
both stages can run against a pretend Mac held in memory.

1. Install `IntuneOnboard-1.0.1.pkg` by double-clicking it. The package is
   signed and notarized by Apple, so you will not get a warning about an
   unidentified developer.

2. Open Terminal and run:

   ```sh
   open -a "Intune Onboard.app" --args --demo provisioning
   ```

   You should see the provisioning window: a list of items, each finishing in
   turn, with a progress bar. One item fails on purpose so you can see what
   that looks like. Press **⌘L** while it is running — that log panel is the
   only way to see what is happening during real Setup Assistant, where there
   is no Terminal and no Console app.

3. Then the other stage:

   ```sh
   open -a "Intune Onboard.app" --args --demo onboarding
   ```

   This one is interactive. Click through it: pick a wallpaper, review the
   Dock, choose a browser. **None of it is applied** — the demo answers every
   question with a pretend Mac.

If both of those looked right, the product works. Anything that goes wrong
from here is configuration, which is a much easier problem to chase.

---

## Step 2 — Your own configuration, in dry-run

Half an hour. You need one Mac already enrolled in your tenant. Still nothing
at risk: with `dryRun` set, everything renders and **nothing is changed**.

### 2a. Start from this

Save it as `my-settings.plist`. It is a working starting point: one app during
provisioning, a welcome message and a Dock suggestion during onboarding.

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

Change `Contoso`, the colour and the phone number to yours. `dryRun` stays
`true` until step 3.

Two things to know about that file:

- **`organization.name` is the only key you cannot leave out.** Everything
  else has a sensible default.
- **A key this product does not recognise makes the whole profile fail to
  load.** That sounds harsh, and it is deliberate: a misspelled key that was
  quietly ignored would look exactly like a key that did not work, and you
  would have no way to tell. The next step catches that before you upload.

### 2b. Check it before you upload

The checker refuses to read a file that is not owned by root, because it is
the same code path that loads real configuration on a real Mac. So copy it
somewhere and hand it to root first:

```sh
sudo cp my-settings.plist /tmp/check.plist
sudo chown root:wheel /tmp/check.plist
sudo chmod 644 /tmp/check.plist
sudo "/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd" \
    validate-config --path /tmp/check.plist
```

A good result names what it found:

```
OK — schemaVersion 1, 1 provisioning item(s), 2 onboarding item(s)
```

**Read those counts.** They are the point of the check. A typo inside an item
is reported with its exact location, like this:

```
configuration invalid:
  - config.onboarding.items[1].dockStrategie: unknown key — nothing in this
    build reads it here (misspelled, or from an older schema?)
```

> **Check the `.plist`, not the `.mobileconfig`.** If you point
> `validate-config` at the wrapped profile you are about to upload, it reports
> `OK — 0 provisioning item(s), 0 onboarding item(s)` — because the settings
> are nested one level down inside a wrapped profile and it never sees them.
> Zero-and-zero is the tell that you checked the wrong file.

### 2c. Wrap it for Intune

Intune needs the settings inside a profile wrapper. Save this as `wrap.py`
next to your settings file and run `python3 wrap.py my-settings.plist my-profile.mobileconfig`:

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

Keep editing the `.plist` and re-wrapping. Do not hand-edit the
`.mobileconfig` — you will lose track of which file is the real one.

### 2d. Upload it

In the Intune admin center:

**Devices → Configuration → Create → New policy → macOS →
Templates → Custom.** Give it a name, upload `my-profile.mobileconfig`.

Then assign it to a **device** group. Not a user group.

Both of those choices matter more than they look:

- **Custom, not Preference file.** The Preference file template rejects a
  wrapped profile with error `-2016341103`. If you see that code, this is why.
- **Device-assigned, not user-assigned.** A user-assigned profile is
  delivered to a per-user location that the background service never reads —
  and which does not exist at all during Setup Assistant, before anyone has
  logged in. A user-assigned profile is the single most common reason for
  "nothing happens".

### 2e. See it

On your enrolled test Mac, make sure the profile has arrived
(**System Settings → General → Device Management**), then log out and log
back in.

You should get the onboarding window with your organisation's name and
colour, and a yellow **DRY RUN** badge. Click through the steps: they will
report success and change nothing. Because nothing was really done, it comes
back at every login until you remove `dryRun`.

<!-- Screenshot slot 2: onboarding cards with the DRY RUN badge visible. -->

---

## Step 3 — For real

Now you need a Mac you can erase, because provisioning only happens during
Setup Assistant, and Setup Assistant only happens on a Mac that has not been
set up yet.

1. **Remove `dryRun`** from your settings, re-wrap, re-upload.
2. **Upload the package.** Apps → macOS → Line-of-business app →
   `IntuneOnboard-1.0.1.pkg`, assigned to the same device group as
   **required**.
3. **Add the background-items profile:** `managed-login-items.mobileconfig`,
   supplied alongside the package, as another Custom profile on the same
   group. Without it
   macOS tells the user "Background Items Added" during enrollment and offers
   them a switch that turns onboarding off.
4. **Optional but worth it:** `custom-attribute-onboard-status.sh` under
   Devices → Scripts and remediations → macOS custom attributes, type
   **String**, "Run script as signed-in user" set to **No**. It reports both
   stages in one line so you can see across a fleet.

**Deploy the profile before the package.** If the package lands first the Mac
waits for configuration for ten minutes and then gives up until the next
login. Nothing is broken, it is just slower than it needed to be.

Then erase the test Mac and enroll it. During Setup Assistant you will see
provisioning working. **⌘L** shows the log; it is the only way to see
anything at that point.

Full deployment reference, including the order and why: `Operations.md`.

---

## When something does not work

Find what you are seeing in the left column.

| What you see | What it is |
|---|---|
| **Nothing at all.** No window, ever, on a Mac that has the profile and the app. | Almost certainly `requireADE: true` on a Mac that was not enrolled through Automated Device Enrollment. This is designed silence: the Mac is out of scope, so it is shown nothing rather than a message it cannot act on. Run `sudo onboardd status` — it says `not applicable (requireADE)`. Set `requireADE` to `false` while testing on manually enrolled Macs. |
| **"Waiting for the configuration profile…"**, then it gives up. | The profile has not arrived, or it is assigned to a **user** group instead of a device group. Check System Settings → General → Device Management. |
| Intune refuses the upload, error **`-2016341103`**. | You used the **Preference file** template. It has to be **Templates → Custom**. |
| **"Configuration invalid"**, naming a key. | A misspelled key, or one from before version 1.0. The message gives the exact path. Run `validate-config` (step 2b) before uploading — it catches this in a second instead of a deployment cycle. |
| The provisioning window **never appears on a Mac you already set up**. | Working as intended: it finished once and will not repeat. To run it again: `sudo onboardd reset --device`. |
| Steps run, report success, but **nothing actually changes**. | `dryRun` is still set. |
| `validate-config` says **`0 provisioning item(s), 0 onboarding item(s)`**. | You checked the wrapped `.mobileconfig` instead of the settings `.plist`. See the note in step 2b. |
| An app in the Dock list **did not get added**. | Apps that are not installed are skipped rather than failing the step, and the step reports "X added, Y skipped". Listing an app that only some Macs have is safe by design. |
| One provisioning item **failed** and the Mac carried on. | Also by design, if the item is not `required`. The item is retried up to three times, then the failure waits at the next login with a **Try again** button. |

Two logs, if you need them:

```sh
sudo onboardd status                    # one line, both stages
sudo cat /var/log/IntuneOnboard/onboard.log
```

`onboardd` lives at
`/Applications/Utilities/Intune Onboard.app/Contents/MacOS/onboardd` —
add that to your `PATH` or type it out.

---

## Starting over

Useful while you are learning, and safe:

```sh
# Run provisioning again on this Mac
sudo onboardd reset --device

# Let one user go through onboarding again
rm ~/Library/Application\ Support/IntuneOnboard/state/user.json

# Remove everything: the app, the background services, all state
sudo sh uninstall.sh
```

Both stages work out what they can from the Mac itself, so a step whose result
is already true finishes without redoing the work. Re-running is cheap.

---

## Where to go next

- **`Configuration.md`** — every available key, with its default and what it
  does. The reference you will live in once you are past this guide.
- **`be.jordythery.intuneonboard.example.plist`** — every key in one file with
  a comment on each. Good for browsing what is possible.
- **`Operations.md`** — deploying properly: the four things, the order, and
  how to read the state across a fleet.

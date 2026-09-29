# Deploy

| File | Purpose |
|---|---|
| `be.jordythery.intuneonboard.mobileconfig` | Starter settings profile. **Upload this one.** |
| `be.jordythery.intuneonboard.plist` | The same settings as a bare plist, for `onboardd validate-config --path` |
| `be.jordythery.intuneonboard.example.mobileconfig` | Every key, as a profile. Generated from the `.plist` below by `Scripts/make-example-profile.sh` |
| `be.jordythery.intuneonboard.example.plist` | Every key, with its default and effect in a comment |
| `managed-login-items.mobileconfig` | Approves the launchd jobs, so users cannot disable them in Login Items |
| `custom-attribute-onboard-status.sh` | Intune custom attribute reporting both stages |

## Uploading the settings profile

Devices → Configuration → macOS → Templates → **Custom**, assigned to a
**device** group.

- The Preference file template rejects these files (`-2016341103`).
- A user-assigned profile is not read: the daemon reads only
  `/Library/Managed Preferences/be.jordythery.intuneonboard.plist`.

The example profile is safe to deploy as a test: its items are optional,
`demoteUser` is disabled and `requireADE` is off. A path-based `script` item and
the wallpaper `sha256` are commented out, because they need files that do not
exist on a new Mac.

See [`../Docs/Operations.md`](../Docs/Operations.md) for deployment order.

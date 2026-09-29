# Configuration reference

Preference domain `be.jordythery.intuneonboard`, read only from
`/Library/Managed Preferences/be.jordythery.intuneonboard.plist`. Deliver it as
a device-assigned Custom configuration profile. User-level preferences are
ignored because the configuration can run scripts as root.

Validate a file with `onboardd validate-config --path <plist>` (see
[Validating](#validating)). An unknown key makes the profile invalid.

Examples on this page are fragments of the settings dictionary.
`Deploy/be.jordythery.intuneonboard.example.plist` is a complete profile with
every key.

## Value types

| Type | Forms |
|---|---|
| localized string | A string, or a dictionary of language code → string. Resolved as exact tag → base language (`nl-BE` → `nl`) → `en` → first key. |
| icon | `symbol:<SF Symbol>`, `name:<asset>`, an absolute path to an image or `.app`, `bundleid:<id>`, or an `https` URL. Unresolvable icons show a placeholder. |
| URL | `https` only. |

```xml
<key>title</key>
<dict>
	<key>en</key>
	<string>Setting up your Mac</string>
	<key>nl</key>
	<string>Je Mac wordt ingesteld</string>
	<key>fr</key>
	<string>Configuration de votre Mac</string>
</dict>
```

The app's own text is English, Dutch or French, following the Mac's language.
Include an `en` entry in every localized dictionary.

## Top level

| Key | Type | Default | Notes |
|---|---|---|---|
| `schemaVersion` | int | `1` | Other versions are rejected. |
| `dryRun` | bool | `false` | Renders both stages without changing the Mac or writing completion markers. A **DRY RUN** badge is shown. |
| `requireADE` | bool | `false` | If the Mac was not enrolled through ADE, neither stage runs and nothing is shown (exit 12). |
| `organization` | dict | — | [Below](#organization). |
| `network` | dict | — | [Below](#network). |
| `installomator` | dict | — | [Below](#installomator). |
| `provisioning` | dict | — | [Below](#provisioning). |
| `onboarding` | dict | — | [Below](#onboarding). |
| `logging` | dict | — | `maxFileSizeMB` (int, `10`), `keepArchives` (int, `3`). |

## `organization`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | Shown when there is no `logo`. |
| `logo` | icon | — | Window header. |
| `accentColor` | string | system blue | `#RRGGBB`. |
| `supportText` | localized | — | Shown when provisioning fails. |
| `supportURL` | URL | — | |
| `help` | dict | — | Adds a help button. Keys: `title` (localized), `message` (localized, Markdown), `url` (URL, shown as a QR code). |

```xml
<key>organization</key>
<dict>
	<key>name</key>
	<string>Contoso</string>
	<key>accentColor</key>
	<string>#0F6CBD</string>
	<key>logo</key>
	<string>https://example.com/logo.png</string>
	<key>help</key>
	<dict>
		<key>message</key>
		<string>Scan this code to reach the **IT service desk**.</string>
		<key>url</key>
		<string>https://example.com/support</string>
	</dict>
</dict>
```

Provisioning runs before other content reaches the Mac, so a local `logo` path
is usually empty at that point. Use an `https` URL that returns the image
without authentication (`curl -sSI <url>` should report `200` and an image
content type). For item icons, `bundleid:` resolves as soon as the app is
installed.

## `network`

| Key | Type | Default | Notes |
|---|---|---|---|
| `requiredURLs` | [URL] | `[]` | Provisioning stops if any is unreachable (exit 13). |
| `warnURLs` | [URL] | `[]` | Logged only. |
| `timeoutSeconds` | int | `30` | Per URL. |

## `installomator`

| Key | Type | Default |
|---|---|---|
| `defaultOptions` | [string] | `NOTIFY=silent`, `BLOCKING_PROCESS_ACTION=ignore`, `INSTALL=force`, `IGNORE_APP_STORE_APPS=yes`, `LOGGING=REQ` |

Options apply to every `installomator` item. Each must match
`^[A-Z_]+=[A-Za-z0-9_.,:/@-]*$`. A value containing spaces must be quoted:
`LOGO="/Library/Application Support/logo.png"`; quoted values may not contain
`"`, `` ` ``, `$` or `\`. `DEBUG` is not accepted; `DEBUG=0` is always
appended.

## `provisioning`

| Key | Type | Default | Notes |
|---|---|---|---|
| `title`, `message` | localized | — | |
| `showDeviceInfo` | bool | `true` | Shows device details in the window. |
| `allowContinueOnError` | bool | `false` | See [Failures](#failures). |
| `deviceNameTemplate` | string | — | See [Device name](#device-name). |
| `items` | array | required | [Provisioning items](#provisioning-items). |

### Failures

- Items run in order; a failure does not stop the remaining items.
- A failed **required** item withholds the completion marker.
- A failed item is retried automatically up to three times. After that it is
  retried only when a user presses **Try again**. Preflight failures follow the
  same limit.
- During Setup Assistant the window shows the failure and `supportText`. With
  `allowContinueOnError` it closes after five seconds; without it, it stays
  until the session ends.
- At the next login the failure is shown before onboarding, with **Try again**
  and **Continue anyway**. **Continue anyway** requires `allowContinueOnError`
  unless onboarding is configured. Dismissing the window is remembered until a
  later run fails.

### Device name

Sets `ComputerName` to the rendered template, and `LocalHostName` and
`HostName` to a sanitized form (ASCII letters, digits and hyphens, at most 63
characters). Applied before the items run.

| Token | Value |
|---|---|
| `%serial%` | Serial number |
| `%udid%` | Hardware UUID |
| `%model%` | Model family, e.g. `MacBook Air` |
| `%model-short%` | First word of the model |

Modifiers: `%serial:6%` first six characters, `%serial:-6%` last six,
`%serial:=6%` middle six. `%%` is a literal `%`. Unknown tokens are
configuration errors. If a token has no value on the Mac, the name is left
unchanged.

```xml
<key>deviceNameTemplate</key>
<string>CONTOSO-%serial:-6%</string>
```

## `onboarding`

| Key | Type | Default | Notes |
|---|---|---|---|
| `title`, `message` | localized | — | |
| `launchOnCompletion` | string | — | App path, `bundleid:` or URL, opened when the user presses Done. |
| `hideOtherApps` | bool | `true` | Hides other apps once, at launch. |
| `allowQuit` | bool | `true` | `false` disables quitting, closing and minimizing until all steps are done. |
| `windowPosition` | string | `center` | `center` or `focus`. `focus` covers every screen behind the window. |
| `background` | icon | current wallpaper | Backdrop for `focus`. |
| `blur` | bool | `false` | Blurs the `focus` backdrop. |
| `items` | array | required | [Onboarding items](#onboarding-items). |

With `focus`, the backdrop is lifted while an `open` step is in progress and
removed when all steps are done. Preview with
`--demo onboarding --focus [blur]`. ⌃⌥⌘Q always quits.

## Item keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `id` | string | required | `[A-Za-z0-9._-]{1,64}`, unique per stage. Keep it stable; state is stored by id. |
| `kind` | string | required | |
| `title`, `subtitle` | localized | per kind | |
| `icon` | icon | per kind | |
| `required` | bool | `true` | A failure withholds the completion marker. |
| `enabled` | bool | `true` | Disabled items are skipped. |
| `timeout` | int | per kind | Seconds. Provisioning items only. |
| `validatePath` | string | — | Must exist after the item succeeds, or it fails. |

Onboarding items also accept `mode` (`automatic` or `interactive`) and
`buttonTitle` (localized). `defaultApps` and `open` are always interactive.

An item ends as **success**, **skipped** (not applicable, or already in the
desired state) or **failed**. The completion marker is written when every
required item succeeded or was skipped.

## Provisioning items

### `installomator`

Timeout 1800.

| Key | Type | Notes |
|---|---|---|
| `label` | string | Required. |
| `options` | [string] | Added after `defaultOptions`; same rules. |

### `script`

Timeout 1800.

| Key | Type | Default | Notes |
|---|---|---|---|
| `script` or `path` | string | one required | `path` must be a regular file owned by root and not writable by group or others. |
| `interpreter` | string | `/bin/zsh` | `/bin/zsh` or `/bin/bash`. |
| `arguments` | [string] | `[]` | |
| `successExitCodes` | [int] | `[0]` | |
| `statusFromOutput` | bool | `true` | Output lines starting with `status:` update the item's status text. |

Scripts run as root with a minimal environment, from a copy in a root-only
temporary directory; `$0` is that copy's path.

### `wait`

| Key | Type | Notes |
|---|---|---|
| `seconds` | int | Required. Also the timeout. |
| `message` | localized | |

### `awaitPath`

Timeout 300.

| Key | Type | Default |
|---|---|---|
| `path` | string | required |
| `condition` | string | `exists` or `absent`; default `exists` |

## Onboarding items

A single value asks the user to confirm; an array lets the user choose.

### `message`

Informational. Completes when viewed.

### `wallpaper`

| Key | Type | Default | Notes |
|---|---|---|---|
| `source` | path or URL, or an array | required | URLs are downloaded to `/Library/Application Support/IntuneOnboard/`. |
| `sha256` | string | — | Verified after download. Only with a single source. |
| `allowKeepExisting` | bool | `false` | Offers keeping the current wallpaper. |

A local `source` that does not exist is skipped.

### `dock`

| Key | Type | Default | Notes |
|---|---|---|---|
| `dockStrategy` | `keep`, `add` or `replace`, or an array | `add` | An array shows the options with a preview. |
| `items` | [string] | `[]` | Paths or `bundleid:`. Missing apps are skipped. |
| `waitForItemsTimeout` | int | `0` | Seconds to wait for listed apps to be installed. |
| `restartDock` | bool | `true` | |

### `defaultApps`

| Key | Type | Default | Notes |
|---|---|---|---|
| `browser` | string or array | — | Bundle id(s). |
| `urlSchemes` | dict | — | Scheme → bundle id(s), e.g. `mailto`. |
| `types` | dict | — | UTI → bundle id(s). |
| `allowKeepExisting` | bool | `false` | Offers the current handler as a choice. |
| `explanation` | localized | — | Shown before macOS asks the user to confirm the change. |

At least one of `browser`, `urlSchemes` or `types` is required. Targets
already set to a listed app, and targets whose apps are not installed, are
skipped.

### `open`

| Key | Type | Default | Notes |
|---|---|---|---|
| `target` | string | required | App path, `bundleid:` or URL. |
| `completion` | string | `manual` | `manual` (the user confirms) or `validatePath`. |

### `demoteUser`

Removes the signed-in user from the admin group.

| Key | Type | Default | Notes |
|---|---|---|---|
| `exclude` | [string] | `[]` | Accounts never demoted. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed |
| `10` | Not running as root |
| `12` | Not ADE-enrolled while `requireADE` is set |
| `13` | A required URL is unreachable |
| `30` | Completed with errors, or no configuration within ten minutes |

## Validating

`validate-config --path` only reads a root-owned file that is not group- or
world-writable:

```sh
sudo install -o root -g wheel -m 644 my-settings.plist /tmp/check.plist
sudo onboardd validate-config --path /tmp/check.plist
```

Validate the bare `.plist`; a wrapped `.mobileconfig` reports `0` items. For
upload, the file must not start with a BOM or whitespace, and XML comments
must not contain `--`.

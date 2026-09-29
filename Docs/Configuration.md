# Configuration reference

Domain: **`be.jordythery.intuneonboard`**, read exclusively from
`/Library/Managed Preferences/be.jordythery.intuneonboard.plist`. User-level
defaults are ignored — the config contains scripts that run as root, so a
user-writable source would be a privilege escalation.

Deploy as an Intune **Preference file** or a custom **.mobileconfig** — an
example of each is supplied. If the profile lands after the app starts, the app
shows "Waiting for configuration…" and polls for ten minutes; if the
profile is later than that, the next login tries again.

Validate with: `onboardd validate-config [--path <plist>]`.

**The two stages.** `provisioning` runs during Setup Assistant as root, before
any user exists: installs, root scripts, waits, naming the Mac. `onboarding`
runs at first login as the signed-in user: wallpaper, Dock, default apps,
"open this" steps, admin demotion. Each has its own dictionary below.

> **Kept honest by a test.** `referenceProfileDocumentsEveryKeyTheParserReads`
> derives the key list from the parser's own source, so a key added without
> being written up here — or documented here after being removed — fails the
> build. The count is deliberately not quoted: it went stale twice.

## Start here: branding the card

The four keys that change how provisioning looks, all under `organization`:

```xml
<key>organization</key>
<dict>
	<key>name</key>
	<string>Contoso</string>
	<key>accentColor</key>
	<string>#0F6CBD</string>
	<key>logo</key>
	<string>/Library/Application Support/Contoso/logo.png</string>
	<key>help</key>
	<dict>
		<key>title</key>
		<string>Need a hand?</string>
		<key>message</key>
		<string>Scan this code to reach the **IT service desk**.</string>
		<key>url</key>
		<string>https://example.com/support</string>
	</dict>
</dict>
```

> **Examples on this page are fragments.** Each shows only the keys under
> discussion, and belongs inside the settings dictionary of a profile — not
> pasted on its own. `be.jordythery.intuneonboard.example.plist`, supplied
> alongside the package, is a complete document with every key in place.

- `accentColor` colours the progress bar and the controls, so it is the
  single highest-value key.
- `logo` is the identity mark in the window's header.
- Without one, `name` is drawn as text — which is a perfectly good first step.

### Getting the artwork onto the Mac

This is the part that catches people out. Provisioning runs **before** anything has
been copied to the Mac, so a path like the one above is empty at that moment
and the card falls back to a placeholder glyph. Three ways round it, in order of
how well they work during Setup Assistant:

| Approach | Works in provisioning | Notes |
|---|---|---|
| `https://…` URL | Yes | Fetched once per process. Must be reachable *unauthenticated* — a link that redirects to a login page, or a CDN that refuses non-browser clients, yields the placeholder. Host it somewhere plain (blob storage, your own web server). |
| Intune script that writes the file, ordered before this profile | Usually | Racy: nothing guarantees it lands before the card appears. |
| Path filled by a later package | No | Fine for the onboarding stage, too late for provisioning. |

A quick way to prove a URL is usable from a clean Mac:
`curl -sSI <url>` — anything other than a `200` with an image content type will
show as a placeholder.

<!-- repo-only -->
**Confirmed on hardware (2026-09-17):** S3-style object URLs and app-icon
CDNs that serve plain PNGs to any client both render. Wikipedia's
`upload.wikimedia.org` thumbnails do **not** — they were the placeholder
glyphs in the first branded run.
<!-- /repo-only -->

Item icons behave the same way. `bundleid:com.microsoft.edgemac` is the right
choice for apps being installed: it resolves as soon as the app exists, so
the rows' icons fill in during the run. The placeholder before that is expected.

## Value types

| Type | Forms |
|---|---|
| **localized string** | Plain string, or dict of language code → string. Resolution: exact tag → base language (`nl-BE` → `nl`) → `en` → first key (sorted). Language source: the console user's preferred languages; in Setup Assistant mode, the system language. |
| **icon** | `symbol:<SF Symbol>` · `name:<named image>` · absolute path to an image or `.app` · `bundleid:<id>` · https URL (fetched once per process). Non-https URLs are rejected. Anything that can't be resolved falls back to a placeholder symbol — Provisioning routinely runs before the apps it names exist, so `bundleid:` icons appear as they install. |
| **URL** | https only, everywhere. |

### Languages

The app's own text — buttons, statuses, headings, the log panel — ships in
**English, Dutch and French**, and follows the Mac's language automatically.
Nothing in the profile selects it.

Text *you* supply is a separate matter: any **localized string** above takes
either one string or a dictionary of language code → string, and that is how
your titles, messages and button labels get translated. A plain string is used
whatever the Mac's language is, so it is the right choice for a name that
shouldn't change.

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

A language you don't supply falls back as described in the table above, ending
at `en` — so an `en` entry is worth having in every dictionary.

## Top level

| Key | Type | Default | Notes |
|---|---|---|---|
| `schemaVersion` | int | `1` | Any other major version → refuse to run, log loudly. |
| `dryRun` | bool | `false` | Dry run: both stages render everything and change nothing — provisioning items simulated, onboarding actions applied to an in-memory overlay, no markers written, so the run repeats until the key is removed. Both screens wear a DRY RUN badge; a device marker from an earlier real run does not stop the dry run. |
| `organization` | dict | — | See below. |
| `requireADE` | bool | `false` | Checked via `profiles status -type enrollment`; failure → exit 12. **Both stages stop and nothing is shown**: an ineligible Mac gets neither provisioning nor onboarding, and no window at all — it was never in scope, and its owner cannot ADE-enrol it retroactively. `onboardd status` reports `provisioning: not applicable (requireADE)` so a fleet view can tell it apart from a Mac the package never reached. The user session asks `profiles` itself rather than waiting for the daemon to report it, and the refusal is shown at every login until the enrollment or the profile is fixed. The other preflight failures stop provisioning only — onboarding is still worth doing when an endpoint was merely unreachable. |
| `network` | dict | — | See below. |
| `installomator` | dict | — | See below. |
| `provisioning` | dict | — | The Setup Assistant stage, run as root. See below. |
| `onboarding` | dict | — | The per-user stage, run at first login. See below. |
| `logging` | dict | — | `maxFileSizeMB` (int, 10), `keepArchives` (int, 3). |

### `organization`

| Key | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | Shown in the header when there is no `logo`. |
| `logo` | icon | — | The identity mark in the window's header. |
| `accentColor` | string | system blue | `#RRGGBB`. Colours the progress bar and controls. |
| `help` | dict | — | Shows a circled question mark in the card's lower right. See below. |
| `supportText` | localized | — | Shown under a **failed** provisioning run, where the next move is a phone call. Not shown otherwise: the footer carries a fixed credit line, and `help` is the everyday route to the service desk. Worth setting — it is the one line a stranded user reads. |
| `supportURL` | URL | — | https. |

#### `organization.help`

Any one key is enough; with none, no button appears.

| Key | Type | Notes |
|---|---|---|
| `title` | localized | Popover heading. |
| `message` | localized | Popover body. Markdown is rendered. |
| `url` | URL | https. Rendered **as a QR code**, not a link — during Setup Assistant there is no browser and no signed-in user, but everyone has a phone. |

### `network`

| Key | Type | Default | Notes |
|---|---|---|---|
| `requiredURLs` | [URL] | `[]` | Preflight fails when unreachable (exit 13). |
| `warnURLs` | [URL] | `[]` | Logged only. GitHub is *not* required — Installomator is bundled. |
| `timeoutSeconds` | int | `30` | Per URL. |

### `installomator`

| Key | Type | Default | Notes |
|---|---|---|---|
| `defaultOptions` | [string] | `NOTIFY=silent`, `BLOCKING_PROCESS_ACTION=ignore`, `INSTALL=force`, `IGNORE_APP_STORE_APPS=yes`, `LOGGING=REQ` | Applied to every installomator item. |

Options must match `^[A-Z_]+=[A-Za-z0-9_.,:/ @-]*$` (they are `eval`'d by
Installomator). `DEBUG=` is rejected at validation time in any position;
the app always appends `DEBUG=0` last, so config can never re-enable dry-run.

### `provisioning`

| Key | Type | Default |
|---|---|---|
| `title`, `message` | localized | — |
| `showDeviceInfo` | bool | `true` |
| `allowContinueOnError` | bool | `false` |
| `deviceNameTemplate` | string | — |
| `items` | array | required |

#### What happens when an item fails

Failing an item never stops the run: the remaining items still execute. What
a failure changes is the ending, and `allowContinueOnError` decides how much.

A failed **required** item withholds the device marker. Over Setup Assistant
the card reports it and then gets out of the way — after five seconds with
`allowContinueOnError`, or by staying up to be read without it. There is no
button either way: nobody is at the keyboard during enrollment, and the
failure is already in the log and the Intune attribute.

A failed run also shows the organization's `supportText` — or a generic
"contact your IT service desk" when the profile has none. Over Setup
Assistant there are no buttons, so without it the screen states a problem and
offers nothing; the next move there is a phone call, and it should say so.

The three attempts happen wherever a card is up, which is not always Setup
Assistant. With `allowContinueOnError` the kiosk clears itself after the
first failure, so the daemon has nobody polling it and the remaining
attempts fall to the first login instead. Without the key the card stays,
and all three happen during enrollment. Either way the Mac gets three goes.

The same cap applies to **preflight**. It has no item records to judge, so
it counts its own consecutive failures and stops after three; a preflight
that passes clears the count, because a network that came back should leave
no trace of having been away.

A card left up keeps polling, and launchd re-spawns the daemon on demand for
each poll, so a failed run starts again within seconds. That is how a Mac
heals itself during enrollment when the fault was transient — a slow CDN, a
network that came up late. It is capped at **three attempts per item**: past
that the failure stands, the marker stays withheld, and the log says
`not retrying automatically`. Without the cap the same mechanism re-downloads
and re-installs roughly every fifteen seconds for a fault that is never going
to clear.

Once every item is terminal and the failed ones are out of attempts, the
daemon stops before doing anything at all: no rename, no preflight, no
republished "checking this Mac…". The item cap alone left the run itself
looping, which reset the card — and wiped its buttons — every ten seconds.
**Try again** is then the only thing that starts it over.

The decision belongs to the first login instead. A Mac that ended
`completedWithErrors` shows the provisioning card **before** onboarding, with
**Try again** and — when `allowContinueOnError` is set — **Continue anyway**.
Dismissing it is remembered per user, keyed to the run that produced it: a
settled failure never runs again, so the card does not return at the next
login. A *newer* failed run brings it back, because that is genuinely new
news. The failure itself stays visible in `onboardd status`, the Intune
attribute and the log throughout — only the interruption stops repeating.

A way past is always offered here, even with `allowContinueOnError: false`:
the person is present, the onboarding steps behind the card are theirs to do,
and an app that failed to install is not a reason to strand them. The key
keeps its full meaning over Setup Assistant, where it decides whether the
card clears itself. The window's close button is taken away while this card
is up, so the button is the way through — closing it left the app with no
window and no Dock icon, which is a dead end.

Either one hands over to onboarding in the same launch; the takeover
(`hideOtherApps`, `allowQuit`, `windowPosition`) only starts once it does, so
a locked window can never sit over a card whose only button is Try again.
A retry re-runs the failed and unfinished items, nothing else, and clears the
attempt cap — someone pressing it has usually just fixed something.

#### `deviceNameTemplate`

Names the Mac before the items run, with no interactive data entry. The daemon sets `ComputerName` to the rendered name verbatim, and
`LocalHostName`/`HostName` to a Bonjour-sanitized version (ASCII letters,
digits and hyphens, spaces/underscores become hyphens, max 63 characters).

Tokens are device-derived only. User-entry tokens (`%email%`, `%assetTag%`…)
would require prompting someone during Setup Assistant, which this product
does not do, and Intune exposes no stable on-device source for the enrolling
user before login:

| Token | Value | Example |
|---|---|---|
| `%serial%` | Serial number (IOKit) | `C304JQC4KM` |
| `%udid%` | IOPlatformUUID | `564D…` |
| `%model%` | Marketing family | `MacBook Air` |
| `%model-short%` | First word of the model | `MacBook` |

Substring modifiers per token: `%serial:6%` keeps the first six characters,
`%serial:-6%` the last six, `%serial:=6%` the center six. `%%` is a literal
`%`. An unknown token or malformed modifier is a configuration error (the
profile is rejected at parse time). A token with no value on the device leaves
the name unchanged — never a partial name. Under `dryRun` the name is rendered
and logged but not applied.

### `onboarding`

| Key | Type | Default | Notes |
|---|---|---|---|
| `title`, `message` | localized | — | |
| `launchOnCompletion` | string | — | Opened when the user presses Done: app path, `bundleid:`, or any URL with a scheme. The onboarding's only post-run hook. |
| `hideOtherApps` | bool | `true` | Hide other apps when the onboarding launches. Fires **once, at launch** — see `windowPosition` to actually hold the screen. Suppressed under `dryRun`: a dry run must not rearrange the user's session. |
| `allowQuit` | bool | `true` | `false` removes ⌘Q, greys the close **and minimize** buttons, and keeps the window above other apps until every step is done. Minimize goes too because the app has no Dock icon, so a minimized window would have nowhere to come back from. ⌃⌥⌘Q remains the administrator's way out. |
| `windowPosition` | string | `center` | `center` or `focus`. Anything else is a configuration error rather than a silent `center`: a profile asking for a layout it won't get should say so. |
| `background` | icon source | current wallpaper | Fills the focus backdrop. Ignored unless `windowPosition` is `focus`. |
| `blur` | bool | `false` | Blurs the focus backdrop. Ignored unless `windowPosition` is `focus`. |
| `items` | array | required | |

#### `windowPosition: focus`

`hideOtherApps` is a one-shot nudge: it hides what is open when the onboarding
appears and cannot stop the user launching a browser over it afterwards. It is
not a lock.

`focus` is the lock. A backdrop window fills **every** screen just beneath the
onboarding, so nothing behind it can be seen or clicked. Three rules make it
usable rather than a trap:

- It is **lifted automatically while an `open` step waits on the user** — the
  app the onboarding just told them to sign into is an ordinary window and
  would otherwise be stranded behind the backdrop — and restored the moment
  that step completes.
- It **comes down for good once every step is done**, along with the
  `allowQuit` lock: the point is to keep someone in the flow, not to hold a
  finished window hostage.
- Full-screening is disabled while it is up, since a full-screen window gets
  its own Space and would leave the backdrop behind on the old one.

⌃⌥⌘Q still exits, and the window stays movable.

Review it without deploying a profile: `--demo onboarding --focus`, or
`--demo onboarding --focus blur`.

## Common item keys

| Key | Type | Default | Notes |
|---|---|---|---|
| `id` | string | required | `^[A-Za-z0-9._-]{1,64}$`, unique within its phase. Used for state, so keep it stable. |
| `kind` | string | required | Unknown kind → config error. |
| `title`, `subtitle` | localized | kind-specific | Installomator fallback: `name=` parsed from the bundled label, then the label id. |
| `icon` | icon | kind-specific | |
| `required` | bool | `true` | A failure blocks the completion marker. |
| `enabled` | bool | `true` | Disabled items are recorded as skipped. |
| `timeout` | int | per kind | Seconds. |
| `validatePath` | string | — | Must exist after success, else the item is failed. |

Onboarding items additionally take `mode` (`automatic` \| `interactive`) and
`buttonTitle` (localized). `defaultApps` and `open` are always interactive.

### Item outcomes and markers

- **success** — ran and validated.
- **skipped** — deliberately not applicable (`enabled: false`, already in the
  desired state, optional Dock app missing). Never blocks the marker, even
  when `required` is true.
- **failed** — attempted and did not succeed, or `validatePath` missing.
  Blocks the marker when `required` is true. A configured wallpaper URL that
  fails to download is **failed**.

The device marker is written only when every required provisioning item is
success/skipped; same rule per user for onboarding. A next run retries only
failed/unfinished required items.

## Provisioning kinds

### `installomator` (timeout 1800)

| Key | Type | Notes |
|---|---|---|
| `label` | string | required |
| `options` | [string] | Appended after `defaultOptions` (later wins); same allowlist. |

### `script` (timeout 1800)

| Key | Type | Default | Notes |
|---|---|---|---|
| `script` *or* `path` | string | exactly one | `path` must be root-owned, not group/world-writable. Inline scripts run from a 0700 root-only temp dir. |
| `interpreter` | string | `/bin/zsh` | `/bin/bash` allowed; nothing else. |
| `arguments` | [string] | `[]` | |
| `successExitCodes` | [int] | `[0]` | |
| `statusFromOutput` | bool | `true` | stdout lines starting with `status:` update the row's status text. |

### `wait`

| Key | Type | Notes |
|---|---|---|
| `seconds` | int | required, > 0; also the default timeout |
| `message` | localized | |

### `awaitPath` (timeout 300)

| Key | Type | Default |
|---|---|---|
| `path` | string | required |
| `condition` | string | `exists` (\| `absent`) |

## Onboarding kinds

### `message` (automatic)

Information only — a title and a message; no interaction, viewing the step
completes it. It has no keys beyond the common item keys.

Onboarding-wide shape rule: **scalar means confirm, array means choose.** One
value renders a confirmation; several render a picker the user chooses from.
One rule instead of a per-step flag: a single value can only be accepted,
several have to be chosen between.

### `wallpaper` (automatic)

| Key | Type | Default | Notes |
|---|---|---|---|
| `source` | path \| https URL, or array of them | required | Array → the user picks from a grid. URLs download to `/Library/Application Support/IntuneOnboard/` (root:wheel 0644). |
| `sha256` | string | — | 64 hex chars; verified after download. Only allowed with exactly **one** source — one hash cannot vouch for several files. |
| `allowKeepExisting` | bool | `false` | Offer "keep the current wallpaper" as an outcome. |

Applied once per user with desktoppr; the applied file's hash is recorded in
user state, which is what makes a re-run a skip instead of a re-apply.

### `dock` (automatic)

| Key | Type | Default | Notes |
|---|---|---|---|
| `dockStrategy` | `keep` \| `add` \| `replace`, or array of them | `add` | Array → the user chooses (radio buttons with a Dock preview). "Keep the current Dock" is offered by including `keep`. |
| `items` | [string] | `[]` | Paths or `bundleid:`. Missing apps are skipped, reported "X added, Y skipped". |
| `waitForItemsTimeout` | int | `0` | Wait for apps provisioning is still installing. |
| `restartDock` | bool | `true` | Restarts only this user's Dock, once, after all edits. |

An app the user already has in the Dock counts as done and is left alone:
dockutil exits non-zero rather than duplicate a tile, and treating that as a
failure marked the whole step failed for a Dock that was exactly as
configured. Listing a stock app such as `/System/Applications/Apps.app` was
enough to trigger it. `replace` never showed it, because emptying the Dock
first leaves nothing to collide with.

Tip: add Privileges explicitly with `bundleid:corp.sap.privileges` — the
skip-missing rule handles machines without it.

### `defaultApps` (always interactive)

| Key | Type | Default | Notes |
|---|---|---|---|
| `browser` | string or array | — | Bundle id(s), set via the `http` scheme. Array → the user picks one. |
| `urlSchemes` | dict | — | scheme → bundle id(s), same rule per scheme (e.g. `mailto` offering Outlook or Mail). |
| `types` | dict | — | UTI → bundle id(s), same rule. |
| `allowKeepExisting` | bool | `false` | Offer "keep the current default" as an outcome. |
| `explanation` | localized | — | Shown before triggering: macOS asks the user to confirm a browser change, and from macOS 26.4 every UTI change. Rejection shows state and allows retry. |

Current defaults are checked first; anything already set is skipped to avoid
needless prompts. At least one of `browser`/`urlSchemes`/`types` is required.

With `allowKeepExisting` the app already handling the target joins the
candidates as a tile of its own, captioned **Current** — keeping it is then
something you can see and click, not a link you take on trust. It only
appears when it isn't already one of the configured candidates, and picking
it is exactly "Keep current": no `utiluti` call, so macOS is not asked to
confirm a change that isn't one. A confirm-only step (`allowKeepExisting`
absent) is unchanged, and still pre-selects its single candidate.

### `open` (always interactive)

| Key | Type | Default | Notes |
|---|---|---|---|
| `target` | string | required | App path, `bundleid:`, or URL. |
| `buttonTitle` | localized | — | |
| `completion` | string | `manual` | `manual` (user ticks it off) or `validatePath` (requires `validatePath` on the item). |

### `demoteUser` (automatic, executed by the daemon)

| Key | Type | Default | Notes |
|---|---|---|---|
| `exclude` | [string] | `[]` | Usernames never demoted. **No shipped default** — configure your hidden admin here. |

## Exit codes (`onboardd`)

`10` not root · `11` user session timeout · `12` not ADE · `13` required
network endpoint unreachable · `20` Installomator missing/unusable · `21`
integrity verification failed · `22` update/copy failed · `23` `DEBUG=0` not
verifiable · `30` completed with errors.

## Examples

| File | What it is |
|---|---|
| `be.jordythery.intuneonboard.plist` | A realistic deployment, as a **Preference file**. A small, deployable starting configuration. |
| `be.jordythery.intuneonboard.mobileconfig` | The same settings as a **Custom profile**. |
| `be.jordythery.intuneonboard.example.plist` | **Every key**, each with a comment giving its default and what it does. Start here when you want to see what is available. |
| `be.jordythery.intuneonboard.example.mobileconfig` | The same settings as a Custom profile. Edit the plist and regenerate, rather than this. |

The example profile is deliberately safe to deploy as a smoke test: every
illustrative item is `required: false`, `demoteUser` is `enabled: false`, and
`requireADE` is `false`. Two things are shipped commented out because they
cannot validate on a clean Mac, and **a configuration error is fatal** — the
app refuses to run rather than act on a config it doesn't understand:

- a `script` item referenced by `path` (the file must already exist and be
  root-owned at validation time), and
- `sha256` on the wallpaper (a placeholder hash would fail the item).

All four files are kept in step automatically: each parses and validates, each
`.mobileconfig` matches its `.plist` exactly, and the key list is taken from
the parser itself — so no configuration key can ship without appearing in the
example profile.

### Validating a file before you upload it

```sh
sudo onboardd validate-config --path /path/to/be.jordythery.intuneonboard.plist
```

The file must be root-owned and not group/world-writable (it is read as root
and can contain scripts that run as root), so validate a copy:

```sh
sudo install -o root -g wheel -m 644 my.plist /tmp/check.plist
sudo onboardd validate-config --path /tmp/check.plist
```

One more shape rule, learned the hard way: Intune's **Preference file** upload
wants bare key/value pairs and rejects a wrapped document with
"We couldn't validate your file" (`-2016341103`); the **Custom profile** route
wants a whole profile. Also avoid a BOM or leading whitespace — both break the
upload, and XML comments may not contain `--`, which strict parsers reject.

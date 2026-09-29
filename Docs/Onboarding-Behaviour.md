# Onboarding behaviour

How each onboarding step is evaluated and applied. Keys are in
[`Configuration.md`](Configuration.md).

## Where steps run

Onboarding runs in the app as the signed-in user. Two operations require root
and are performed by the daemon over XPC:

| Operation | Runs in |
|---|---|
| Downloading a wallpaper to `/Library/Application Support/IntuneOnboard/wallpaper` | Daemon |
| Removing the user from the admin group | Daemon |
| desktoppr, dockutil, utiluti, opening apps and URLs | App |

The app sends only an item id (and a source index); the daemon looks up the
URL, hash, exclusion list and console user itself.

## Status

Each step's status is evaluated from the system at every launch, so a change
the user reverts makes the step incomplete again.

| Step | Complete when |
|---|---|
| `message` | It has been viewed. |
| `wallpaper` | The current wallpaper is one of the configured sources. |
| `dock` | It has been applied or skipped. |
| `defaultApps` | Every target is set to one of its candidates, or the user kept the current handler. |
| `open` | `manual`: the user opened it. `validatePath`: the path exists. |
| `demoteUser` | The user is not in the admin group, or is excluded. |

A step that is already complete without having run is recorded as skipped.
The user's completion marker is written when every required step has
succeeded or been skipped.

## Actions

**`wallpaper`.** A local source that does not exist is skipped. A URL source
is downloaded by the daemon, verified against `sha256` if set, and stored
root-owned with mode 0644; a failed download fails the step. The file is then
applied with desktoppr.

**`dock`.** Waits up to `waitForItemsTimeout` for listed apps to be installed.
`replace` removes all items first. Each item is added with dockutil; items not
on the Mac, or already in the Dock, are skipped. The Dock restarts once, at
the end. The step fails if any add fails, but all items are attempted.

**`defaultApps`.** Targets whose candidates are all missing are skipped. Each
remaining target is set with `utiluti url set <scheme> <bundle-id>` (the
browser uses `http`) or `utiluti type set <uti> <bundle-id>`. If the user
declines macOS's confirmation, the step can be retried.

**`open`.** Launches the target as the user. With `windowPosition: focus`, the
launched app is shown above the backdrop.

**`demoteUser`.** Run by the daemon. Excluded accounts and accounts that are
not admins are skipped; otherwise the user is removed with
`dseditgroup -o edit -d <user> -t user admin`. Place this step last.

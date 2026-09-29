# Setup Assistant spike — findings

M0 acceptance: on an ADE Mac enrolled in Intune with Await Final Configuration,
the heartbeat window must appear over Setup Assistant. If it can't, this file
documents why and login-window / first-login becomes the default path.

## Mechanism under test

- Daemon polls `SCDynamicStoreCopyConsoleUser` (2 s interval, M0 only).
- When the console user is `_mbsetupuser`, it runs
  `launchctl asuser <uid> /usr/bin/open -a "Intune Onboard.app" --args --mode setup-assistant --launched-by daemon-asuser-open`.
- The app raises its window to `screenSaver + 1`, borderless, full screen,
  `canJoinAllSpaces`, and logs: mode, user, uid, window level, launch method
  (subsystem `be.jordythery.intuneonboard`, category `app`).

## Test protocol (real hardware, Intune tenant)

1. Erase / fresh ADE enrollment with Await Final Configuration.
2. Deploy the pkg as a required LOB app in device context.
3. To iterate window levels without rebuilding, SSH in during Setup Assistant
   and relaunch with an override (uid from the daemon log):

   ```sh
   launchctl asuser <uid> /usr/bin/open -a "/Applications/Utilities/Intune Onboard.app" \
       --args --mode setup-assistant --launched-by ssh-manual --window-level 2000
   ```

   Reference raw values: normal 0 · floating 3 · screenSaver 1000 (spike
   default is 1001) · CGShieldingWindowLevel() 2000.
4. During Setup Assistant, capture:
   - does the heartbeat window appear, and at what point?
   - `log show --predicate 'subsystem == "be.jordythery.intuneonboard"' --last 30m`
   - what happens when Await Final Configuration releases the device
     (session death, app relaunch behaviour)?

## Results

First hardware run, 2026-09-17 (ADE Mac, Intune tenant, T&C preference pane
enabled so Setup Assistant had an extra step to sit on).

**The mechanism works. `screenSaver + 1` is enough; no need for
`CGShieldingWindowLevel()`.**

Daemon log (`subsystem == "be.jordythery.intuneonboard"`, 7 default messages,
0 errors, 0 faults):

```
00:07:55.154  daemon  onboardd starting, pid 1275
00:07:55.158  daemon  XPC listener up: be.jordythery.intuneonboard.xpc
00:07:55.159  daemon  console user: _mbsetupuser uid=248
00:07:55.160  launch  launching /Applications/Utilities/Intune Onboard.app into uid 248 via launchctl asuser + open
00:07:55.162  daemon  onboardd run starting
00:07:55.581  app     spike: mode=setup-assistant user=_mbsetupuser uid=248 windowLevel=1001 launchedBy=daemon-asuser-open
00:07:55.582  app     spike: (duplicate of the line above, same pid 1285)
```

| Question | Answer |
|---|---|
| Does the window appear over Setup Assistant? | Yes — full screen, at `windowLevel=1001`. |
| At what point? | Once the enrollment screen finished and Setup Assistant advanced to the next pane (the T&C step). Not over the earlier screens. |
| Root daemon sees the pre-login session? | Yes: `_mbsetupuser uid=248` via `SCDynamicStoreCopyConsoleUser`. |
| `launchctl asuser` + `open` into that session? | Yes: app pid 1285 up 0.42 s after the launch line. |
| Await Final Configuration release / session death | **Not observed** — see gaps. |

Await Final Configuration is therefore the right gate: it is the first point at
which the window reliably has a session to appear in. Covering the screens
*before* enrollment completes is not something to design around.

### Second run, same day (artifacts only, heartbeat build) — inconclusive

```
onboard.log     07:25:49.226Z  onboardd run starting        (one line, nothing after)
progress.json   {"engineState":"waitingForConfig","items":[],"updatedAt":"2026-09-17T07:25:49Z"}
status.json     {"deviceComplete":false,"items":{}}
unified.log     header only — the log show matched nothing
```

**This is a snapshot ~4 minutes into the run, not an end state.** The daemon
started at 07:25:49Z (09:25:49 local) and the artifacts were collected between
09:29 and 09:32 local. The config wait is 600 s, so the daemon was still
inside its config wait when the files were taken: the profile had not arrived
*yet*, which is not the same as never arriving. Whether Phase A ran afterwards
is simply not in these artifacts.

Note the shape of the evidence for next time:

- `progress.json` is rewritten on every state transition, so it always shows
  the *latest* state — but `waitingForConfig` while the wait is still open
  means "not yet", not "failed".
- `onboard.log` receives the coordinator's messages only, and the coordinator
  says nothing between "run starting" and the final verdict. A single line is
  therefore the expected look of *any* run that hasn't finished, successful or
  not.
- The unified log is the only place the session and launch lines
  (`console user:`, `launching … into uid`, `window:`) appear, and it came back
  empty — which is why this run can't be read either way.

Collect after the run has actually finished (device marker written or the
600 s wait elapsed), and check
`/Library/Managed Preferences/be.jordythery.intuneonboard.plist` at the time of
collection. Both are now in `Docs/TestRunbook.md`.

### Third run, 0.3.2 on a clean ADE enrollment — the daemon was crash-looping

The profile landed, the kiosk UI appeared over Setup Assistant with the real
configured items, and Microsoft 365 installed successfully — yet nothing was
ever recorded and the run never progressed. Cause:

```
Thread: com.apple.NSXPCListener.service.be.jordythery.intuneonboard.xpc
  _dispatch_assert_queue_fail
  dispatch_assert_queue
  _swift_task_checkIsolatedSwift
  swift_task_isCurrentExecutorWithFlagsImpl
  onboardd                     ← XPCListener.listener(_:shouldAcceptNewConnection:)
  Foundation  service_connection_handler_make_connection
```

`EXC_BREAKPOINT` / SIGTRAP, ~26 crash reports, `runs = 24`.

**The onboardd target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
so `XPCListener` and `OnboardService` were implicitly `@MainActor`.** XPC calls
the listener delegate on its own dispatch queue, the compiler-inserted
isolation check fails, and the process traps — on *every* incoming connection.

Why it appeared only at M3: M3 shipped the first XPC *client*. Before that
nothing ever connected, so the delegate was never invoked. The listener had
been "working" since M2 purely because it was never called.

Consequences seen in the field, all from this one fault:

- The daemon died ~6 s after `run starting`, right when the login-window agent
  first connected. Installomator carried on **orphaned** and installed Office
  successfully at 01:56:44 — but the engine was gone, so no state was
  persisted and the next run re-ran m365 instead of moving on.
- `MachServices` without `KeepAlive` means launchd spawns on demand; the app
  polls every second, so every poll spawned a daemon that trapped instantly —
  the 10-second respawn loop (46 spawns in 7½ minutes in one boot).
- `progress.json` froze at the first instance's `waitingForConfig`, which is
  what made the UI claim to be waiting for a profile that had already arrived.
- Every "daemon not answering over XPC" line in the app log.

Fix: `nonisolated final class` on both `OnboardService` and `XPCListener`.
Verified outside the device by reproducing the exact topology — protocol in a
module without default isolation, delegate compiled with
`-default-isolation MainActor`:

| Delegate | Result |
|---|---|
| unannotated (implicitly `@MainActor`) | traps before entering the delegate |
| `nonisolated` | delegate entered, XPC round trip completes |

Two more faults found in the same run:

- The kiosk window was `.borderless`, and a borderless `NSWindow` has
  `canBecomeKey == false`, so it never receives `keyDown` — the ⌃⌥⌘Q escape
  hatch could not fire in the only modes it exists for. Now
  `[.titled, .fullSizeContentView]` with a transparent hidden titlebar and the
  traffic lights hidden. The window log line carries `canBecomeKey` now.
- Installomator's progress cannot be captured from its stdout: it reassigns
  stdout to `/var/log/Installomator.log` after the start banner, so our sink
  goes silent while the install proceeds. Any live progress must come from
  reading that file.

### Fourth run, 0.3.4 — ACCEPTED

```
sudo onboardd status                                     → provisioning: complete (4/4)
ls /Library/Logs/DiagnosticReports | grep -ci onboardd    → 0
```

Full clean ADE enrollment. Every question this document was opened to answer is
now answered yes:

| | |
|---|---|
| Window over Setup Assistant | ✅ full screen, `windowLevel=1001` |
| Configuration delivered and parsed | ✅ real titles, icons, order, org branding |
| Per-item progress **during Setup Assistant** | ✅ m365 `Installed` ✓ while Edge showed `Installing…`, "1 of 4 complete", bar at 25 % |
| Phase A end to end | ✅ 4/4, marker written |
| Daemon stability | ✅ zero crash reports |
| ⌃⌥⌘Q escape hatch | ✅ fired on hardware |
| User-session handoff | ✅ windowed UI showed the finished state after login |

This also settles the earlier "progress didn't work during Setup Assistant"
observation: it did work — the earlier look was taken during the first item
(Microsoft 365, ~3 minutes), before anything could have changed.

M0, M2 and M3 acceptance all close here.

### Fifth run, 0.3.5 — flicker fix confirmed

```
sudo onboardd status                                     → provisioning: complete (4/4)
ls /Library/Logs/DiagnosticReports | grep -ci onboardd    → 0
```

- Kiosk window closed once when the run finished and **did not reappear**.
- User-session window showed every step complete with a working Done button.

Phase A is proven end to end: launch over Setup Assistant, configuration
delivery, live progress, completion, clean handoff to the user session, and a
working escape hatch — with no crashes.

### Sixth run, 0.3.6 — login behaviour confirmed

- Install clean; kiosk closed during Setup Assistant and stayed closed.
- Desktop showed 4 of 4 complete with a working Done button.
- **Reboot and login: nothing reappeared.**

Phase A is complete and correct across the whole lifecycle, including repeat
logins on a provisioned Mac.

### Remaining after acceptance

- **Kiosk window no longer covers the menu bar.** Making it `.titled` (needed
  for `canBecomeKey`, and so for the escape hatch) means macOS keeps it below
  the menu bar, so the Apple menu and keyboard picker stay reachable during
  Setup Assistant. `NSMenu.setMenuBarVisible(false)` is the likely answer;
  untested.
- **No intra-item progress.** A single long Installomator item is still
  indistinguishable from a stall. Its stdout is unavailable after the start
  banner, so this needs `/var/log/Installomator.log`.
- Content is laid out full-width: on a 3420 px display the rows stretch edge to
  edge with the status label far right, and most of the screen is empty below
  four items. A max content width is wanted.

### Gaps from the first run

- **`⌘Q` quits the app.** Setup Assistant carries on unaffected, but a user
  could dismiss the provisioning UI mid-run. Fixed in M3 from both sides:
  `applicationShouldTerminate` refuses in the kiosk launch modes, and the
  daemon relaunches the UI while `_mbsetupuser` still owns the console.
- **Duplicate `spike:` line** (same pid, 1 ms apart): SwiftUI calls
  `.onAppear` again after `WindowPresenter` swaps `styleMask`/frame.
  Presentation became a one-shot in M3.
- **User-session handoff unverified.** Login failed on this Mac because of an
  unrelated Platform SSO problem, so neither the Await Final Configuration
  release nor first-login launch (`--mode user`) was exercised. `mode=user`
  uses the same `asuser` + `open` path with a different uid, so M3 was not
  blocked on it; re-run this row once PSSO is resolved.

## Placing the card over Setup Assistant (0.4.3 → 0.4.4)

**Setup Assistant does not put its card in a window of its own.** It owns one
full-screen window — the blue backdrop — and draws the rounded card into it as
a subview. Confirmed on a 15-inch Air (1710×1107 pt): the only window owned by
`Setup Assistant` was the full screen, so "match Setup Assistant's panel" made
our window full screen too, stretching the card edge to edge and hiding the
backdrop completely.

0.4.3 was verified against a stand-in that modelled the panel as a separate
798×595 window — a size that came from the stand-in itself, never from
hardware. The check therefore proved only that the code agreed with a wrong
model of Setup Assistant. **Stand-ins have to be built from a measurement, not
from the assumption under test.** The window census now goes into the log line
(`setupAssistantWindows=[…]`) so this is recorded from every run rather than
assumed.

How the card is placed as of 0.4.4:

1. `CGWindowListCopyWindowInfo` for windows owned by `Setup Assistant`. Owner
   name and bounds need no Screen Recording permission; window *titles* would.
2. Candidates must be ≥400×300 (it draws 1×1 helpers) **and cover no more than
   60% of the screen** — above that it is the backdrop, not a card.
3. With a candidate: convert to AppKit coordinates against the **primary**
   screen — `y = screen.maxY - panel.maxY`, x unchanged. Both coordinate
   systems are anchored to the primary display, so a panel on a second display
   converts correctly too.
4. Without one (the normal case): 800×600, centred on the screen. This is what
   the reference does as well — its window is its own size on Apple's backdrop,
   not a copy of Apple's card.
5. `window.setFrame(…)`, twice: SwiftUI reconfigures the window after
   `WindowPresenter` runs.
6. A separate invisible screen-sized window (`KioskBlocker`) swallows clicks,
   borderless so it can never take key focus from ⌃⌥⌘Q / ⌘L.

**Three earlier attempts were 39 pt, 33 pt and 3.5 pt out**, all for the same
reason: the card was positioned *inside* a screen-sized window, which needs the
view's offset from the screen. `ignoresSafeArea` makes the content screen-tall
while it stays anchored at the window's top (so `screenHeight - contentHeight`
reads 0, not the menu bar), and oversized content is centred in its container
(the remaining 3.5 pt). None of it is inferable reliably; a window frame is.

### How to verify without a hardware run

A stand-in plus two throwaway tools make this measurable instead of eyeballed —
worth rebuilding if this area is touched again. The stand-in must be a
**full-screen window with the card as a subview**, which is what Setup
Assistant actually is:

- A red borderless window of a given size with a white rounded subview.
- A comparator that reads both processes' window bounds from the window list.
  Three cases checked: a full-screen stand-in → our window `800×600` centred;
  no stand-in at all → the same; a genuine card-sized window (`760×640`) →
  matched exactly, `left +0.0 top +0.0 right +0.0 bottom +0.0`.
- A red-pixel scan of a `screencapture`, which catches the thing frame-matching
  cannot — whether the card actually *draws* edge to edge inside its window.
  When the two coincided, the only red left inside the card was an 11 pt blob
  at its bottom-right: the ❤️ in "Created by Jordy Thery with ❤️".

Nothing in the arithmetic depends on the display size or the menu bar height,
which is what makes it portable: a notched 14/16-inch has a 39 pt menu bar, an
Air or external display 24 pt, and that difference was one of the earlier bugs.
Bounds are in points, so Retina scaling is irrelevant. Remaining assumptions,
worth watching on other hardware: Setup Assistant is on the display with the
menu bar, and the geometry is read at launch, then re-read on
`didChangeScreenParameters`.

**Open question:** Apple's card size is still unmeasured, because every
screenshot taken so far has our own window over it. One screenshot of the bare
"Setting up your Mac" screen (⌃⌥⌘Q to quit ours first) would settle whether
800×600 is the right size to sit on top of it.

## What the log tabs turned up on the first branded run (0.4.6)

Both new tabs earned their place immediately, and the distinction between them
is the useful part: one was full of noise, the other of real failures.

### Rosetta 2 failed, and `softwareupdated` is the likely reason

The Rosetta 2 tile came back with an orange `exclamationmark.circle` —
**failed, not required**, so the run carried on and the marker was unaffected.
The Installer tab was simultaneously full of:

```
mobileassetd[111]: SUPreferenceManager: Connection proxy failure with error:
  … "The connection to service named com.apple.softwareupdated was invalidated:
  Connection init failed at lookup with error 3 - No such process."
```

Installomator's `rosetta2` label shells out to `softwareupdate
--install-rosetta --agree-to-license`, which needs exactly that daemon. So the
likely cause is that `softwareupdated` is not reachable this early in Setup
Assistant. **Not yet confirmed** — those particular lines carry an earlier
timestamp than the run, so they may predate it; the Installomator tab or
`onboard.log` for that item would settle it.

If it holds, Rosetta belongs in the Phase B checklist (a user session has a
working `softwareupdated`) rather than Phase A. Keeping it `required: false` in
Phase A is harmless either way, which is how the reference profile ships it.

### Intune's Sidecar was returning HTTP 500

The Intune tab showed genuine service-side failures, all Microsoft's end:

```
HttpClientLogger | Network request failed. Method: PUT, StatusCode: 500,
  Description: internalServerError, URL: https://agents.amsub0502.manage.
  microsoft.com/TrafficGateway/TrafficRoutingService/SideCar/…
SidecarService | Failed to receive response from Sidecar GW service
PolicyFetcher | Failed to fetch script policies
PolicyFetcher | Retrying fetch after failing. Attempt 1 … serviceCurrentlyUnavailable
```

Sidecar is Intune's channel for **shell scripts and custom attributes**. It
retries, and provisioning does not depend on it — we do not use Intune scripts
— so this did not affect the run. It matters for two things: any Intune shell
script assigned to the Mac is delayed while this persists, and the M6 custom
attribute (`onboardd status`) rides the same channel. Worth knowing that a
"stuck" custom attribute may be Sidecar, not us.

**These are deliberately not filtered.** Everything filtered out of the panel is
chatter whose absence costs nothing; this is the opposite.

## Notes / deviations

- The LaunchDaemon plist uses `Program` with an absolute path into the app
  bundle rather than `BundleProgram`: `BundleProgram` is resolved relative to a
  bundle only for `SMAppService`-registered daemons, not for plists installed
  into `/Library/LaunchDaemons` by a pkg. `AssociatedBundleIdentifiers` still
  provides Login Items attribution; the Managed Login Items profile (Team ID
  rule) ships in `Deploy/` at M6.

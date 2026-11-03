# Coco Hub UF — orb auto-catch attempts

`uf-tracker.client.luau` is a standalone client-side Luau script. It observes the
verified UF match hierarchy and provides an adjustable spherical orb and diagnostics.
When an eligible football crosses the enabled orb, it attempts a client-side approach
toward the live ball over 0.10 seconds, follows it for 0.20 seconds, then restores the
saved position, rotation and velocities. It aligns the locally discovered CatchBox center
with the ball using its starting offset from the root; if none is found it uses the root.
These durations are config settings, not verified UF catch windows. On first local CatchBox contact (or arrival if no contact callback is received), it
attempts one screen tap through optional executor input APIs. Whether UF accepts that
simulated input remains unverified. It makes no remote
calls and cannot confirm server catch validation. Movement may be visible, rejected or
corrected; this is not guaranteed catching.

Run the complete file in a Roblox client environment. It uses standard Roblox APIs,
with no downloads or external libraries. Clipboard functions are optional and are only used when Copy Result is pressed.
Delta and other executor compatibility requires live testing; it is not certified.

## Controls

The compact panel is 210 × 142 pixels.

- Drag the UF · CATCH v10 title to move the panel with mouse or touch.
- Drag or tap the slider to adjust radius from 5–100 studs, in one-stud steps.
- ON/OFF controls orb visibility, detection and catch attempts; OFF immediately restores a pending move. Lifecycle diagnostics continue.
- Tap sends a standalone input test without moving the character; it also works with tracking OFF.
- Copy Result copies a diagnostic report using optional `setclipboard`/`toclipboard` APIs.
  If unavailable or blocked, selectable text opens below the panel for manual copying.
- The … button opens/closes the selectable diagnostic report without using the clipboard.
- × closes the script and cleans up. Running again replaces the prior instance.

Load the current version in an environment supporting HttpGet and loadstring:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/brookbrookcms-cmyk/Coco-hub-uf/main/uf-tracker.client.luau"))()
```

## Discovery and identity

Discovery uses `Workspace.ParkMatchMap.Replicated.Fields.MatchField.Replicated`
and accepts direct `Football` MeshPart children. A one-second targeted reconciliation
handles delayed hierarchy assembly; a filtered DescendantAdded listener handles new
balls and CatchBoxes. There are no full Workspace scans.

Each observed ball receives one ID and one lifecycle until Destroying. Renaming,
reparenting and later acceleration never create another lifecycle. Initial discovery
cannot recover an already UUID-renamed ball that was never previously observed.
CatchBoxes are validated under
`Workspace.MiniGames.[session].Replicated.Hitboxes.[player].CatchBox`.
OuterShell references are observed as direct football children.

## Boundary semantics

Position and velocity are sampled at 30 Hz. The orb uses the ball center relative to
the HumanoidRootPart, not authoritative collision geometry. A relative-position segment
detects crossings between samples, including outside-to-outside crossings. It triggers
once per Instance, not once per acceleration. This deliberately merges distinct throws
if the game reuses one Instance; the report does not establish a reliable throw separator.

A moving eligible ball first sampled inside triggers once; valid outside-to-outside segments also trigger.
Radius changes, switching off/on and respawn reset the crossing baseline without rearming
an already-triggered ball. Anchored balls and balls moving at 5 studs/s or less do not
trigger. Ball/player position-derived speed above 250 studs/s or sample gaps over 0.25 s
suppress crossings. These are configurable heuristics, not verified UF rules.

Other local scripts can listen to the `BoundaryCrossed` BindableEvent under
`Players.LocalPlayer.PlayerGui.UFTracker`. The payload contains `instance`, `id`,
`position`, `velocity`, `distance`, and `timestamp`. Position and distance are from the
current sample, not an interpolated boundary intersection. The built-in listener attempts movement on this event. The event does not establish a catch.

## Evidence and limits

The report retains the latest 400 timestamped events and the lifetime event count.
It records discovery, transitions, destruction, OuterShell changes, football Touched
contacts with validated CatchBoxes, CatchBox property changes and movement discontinuities.
Raw Instance references are provided in boundary callbacks but omitted from JSON.
It does not yet predict trajectories, classify thrower vs receiver contacts, inspect
possession attributes, or provide manual outcome labeling. Reparenting to a player is
reported as association; contacts and association do not prove possession.

Catch attempts are serialized, once per tracked ball Instance. A simultaneous second
boundary event is logged as skipped rather than queued. Dead or seated characters are
excluded. Closing, switching off or removing the character cancels a pending attempt;
a replacement character is never moved back to the old position. No touch synthesis,
catch input simulation, server bypass or possession confirmation is implemented.

Closing clears the report. Destroyed football records and their event connections are
released. A temporarily unparented but undestroyed ball remains tracked intentionally.

## Validation

Local checks: Lua 5.4-compatible syntax parsing, numerical geometry/inside-first cases,
and restoration guards. `python3 tests/check.py` also runs the full script against the
small Roblox test double in `tests/runtime.lua`: UI boot, touch slider endpoints/release,
inside-first trigger, next-step return, one trigger per Instance, OFF/ON, close and
replacement execution. This requires system liblua5.4. The mock does not implement
Roblox physics, API property validation, network replication or UF catch rules.
Roblox API execution, UI behavior, replication behavior and mobile executor support
require live validation. No server catch behavior or local teleport behavior has been tested in UF.

Live checklist:

1. Start before a throw; check discovery ID, speed, distance and one boundary event.
2. Observe Football → UncaughtFootball → player folder → UUID → destruction;
   all events must retain the same ID. Secondary acceleration must not rearm it.
3. Compare near-thrower and receiver contacts; neither should claim a catch.
4. Repeat with OuterShell, a direct destruction and a newly spawned football.
5. Respawn, change sessions, switch off/on and change radius; ensure no baseline trigger.
6. Drag the panel and slider on mobile, toggle off/on, select report text, rerun, and close; ensure no duplicate
   UI or surviving orb/listeners. Compare a report against manually observed gameplay.

7. With auto catch ON, verify one catch_attempt and next-step return per eligible ball.
   Check original position/orientation/velocity restoration, OFF/close cancellation,
   respawn, death, seated state and overlapping balls. Confirm catch outcome manually;
   neither a successful local move nor player association proves a catch.

## v2 troubleshooting

The status line shows the nearest ball ID/distance and `tries` (local movement attempt
count). `UF match path not found` means the observed hierarchy is absent in this mode;
`No ball` means no eligible ball is currently tracked. Runtime callback errors appear
in the status and diagnostic report, with throttled console warnings. These observations
can identify discovery, trigger or local movement failures; a try does not prove a catch.

## Sending a failure report

Run the latest loader (the title should say `UF · CATCH v10`), leave it ON during a pass
that should enter the orb, then press **Copy Result** and paste the result into this
conversation. `Copied! Send result` means a clipboard function succeeded; otherwise
select and copy the text opened below the panel. The script never sends reports anywhere.

The report includes build/place IDs, expected path presence, targeted field child names,
character readiness, local CatchBox snapshots, active football IDs/positions/speeds,
last detection blocker per ball, attempt count, callback errors, and the latest 400 events.
It includes observed player names/paths from gameplay. Reports distinguish disabled,
missing root, anchored/slow ball, position jumps, outside orb, previously triggered and
player-associated states. Movement skips also record reasons (dead, seated, missing ball,
etc.). No report field asserts that the server accepted a catch.

Local mock checks also cover clipboard success, missing clipboard, throwing clipboard,
alternate clipboard fallback, selectable text and live diagnostic fields. Actual Delta
clipboard support and UF behavior still require the report from a real session.

## v4 timing correction

A live report showed successful local CFrame assignments followed by restoration only
0.05–0.38 ms later. Separate Heartbeat listeners could move and restore within the same
dispatch. Detection and restoration now share one callback: it restores previous moves
at the beginning, before any new detection can run. Returns therefore occur on a later
Heartbeat, independent of listener ordering. Return events include `heldSeconds` and
`heartbeatDelta` to verify timing on the actual client. The regression test reproduced
the old failure with reversed listeners and passes with both listener orders after the fix.
This fixes the observed scheduling bug; it does not establish server-accepted catches.

## v5 slower movement

The v4 live report confirmed a 17–21 ms hold and contact with the local CatchBox, but
no established catch. v5 uses `approachSeconds = 0.10` and `holdSeconds = 0.20` instead
of a one-frame snap. During the approach it interpolates toward the current ball position;
during the hold it follows the live ball. A player-association transition, destruction,
anchoring, unavailable character, OFF or close ends the attempt early. Local association
still does not prove a catch. Concurrent balls do not start overlapping movement attempts.

Diagnostics show approach/hold progress and `catch_movement_started`, `catch_arrived`,
and return timing. Tests check intermediate positions, moving-ball following, local
CatchBox offset alignment, configured timeout, ball destruction during movement, and
OFF/close/duplicate cancellation. Server acceptance and catch input remain unverified.

## v6 local association handling

If the tracked ball becomes associated with the local player's Workspace container,
the movement attempt finishes without restoring the old position or velocities. This
also applies when closing or disabling a pending attempt while that association exists.
`catch_attempt_finished` reports `positionKept` and `associatedPlayer`. If another
player is associated, the script returns normally. Cached association identity survives
ball destruction during the attempt. Association remains observational and is not proof
of possession. The v5 report associated both balls with another player before returning;
it did not establish a local catch followed by a script-induced drop.

Regression checks cover local-association position preservation, OFF after completion,
and normal restoration on other-player association.

## v7 screen-tap attempt

Based on the user's confirmed normal catch control (tapping the screen), v7 attempts
one tap at first local CatchBox contact, with arrival as a fallback. It uses optional
`firesignal(UserInputService.TouchTap, {position}, false)` when supported. If unavailable
or blocked, it tries a paired mouse down/up via VirtualInputManager. A mouse event may
not activate mobile touch-only catch handlers. Neither API is guaranteed in Delta or
other executors. A dispatched event is not proof that UF ran catch logic or accepted a catch.

The most recent unprocessed real TouchTap outside the UI is used when available;
otherwise a point outside the tracker panel is selected. No tap occurs for unrelated
players, disabled tracking, or repeated contact in the same attempt. No remotes are
invented or invoked. Copy Result includes `input` capabilities/results and `catch_input`
events with source, method, dispatch status and errors. These distinguish movement from
input support. Tests cover contact dispatch, arrival deduplication, unavailable input,
and mouse down/up fallback; real UF activation still requires live validation.

## v8 engine touch input

The v7 report showed `firesignal(TouchTap)` returning successfully while no normal catch
animation appeared. v8 removes that input route. It attempts engine touch start (0) and
end (2) using VirtualInputManager:SendTouchEvent, then a mouse press/release if touch
calls fail. The call signature/state values were checked against Roblox's input-testing
code distributed in its client:
[dispatchEvent.lua](https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/b0b3ae8c43bceac05392f05b9c315de03f280ac1/CompiledPackages/DomTestingLibrary/65d10c98/DomTestingLibrary/jsHelpers/dispatchEvent.lua).
Roblox documents [VirtualInputManager](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/VirtualInputManager.yaml)
as an internal service; executor access is not guaranteed. No attempt is made to elevate
permissions. Dispatch success still does not establish that UF activates a catch.

The small Tap button tests this input route without character movement, including while
the orb is OFF. Press it once while eligible to catch and compare the animation with a
normal screen tap. Copy Result records a `manual_input_test` catch_input event with the
method, errors and dispatch status. This avoids needing another full pass to establish
basic input support. Mock tests cover paired engine touch, manual Tap, removal of the
obsolete signal route, mouse fallback and unavailable input. Actual animation and catch
behavior remain unverified outside the user's client.

## v9 coordinate feedback correction

The v8 live report showed test-tap Y coordinates decreasing by exactly 58 pixels on
successive presses. Injected TouchTap events were being accepted as new real-tap
positions, creating a GUI-inset feedback loop. v9 excludes TouchTap observations for
0.35 seconds after injection and adds GuiService:GetGuiInset once when converting the
chosen GUI/touch point to engine screen coordinates. Real taps during that short window
are also intentionally excluded from replay-target recording. The exclusion does not
block UF's input handlers; it only affects this script's observer.

Copy Result now includes ignored-event count, last injected screen point, and per-event
GUI point, screen point and inset. The regression mock uses a 58-pixel inset, generates
TouchTap from injected engine touch events, and checks repeated test presses for stable
coordinates and correct classification. The live catch animation/acceptance still has
not been established. No successful dispatch is reported as a confirmed catch.

## v10 held-input diagnostic experiment

The user confirmed v9 still produced no normal catch animation. v10 tests a 0.06-second
press spanning multiple Heartbeats instead of sending touch down/up in one callback.
This is a hypothesis about deferred input processing, not a confirmed cause or catch fix.
Overlapping presses are suppressed; OFF, close and movement cancellation release any
pending input. Release attempts and actual duration are logged separately.

Copy Result now includes touch/mouse InputBegan/InputEnded observations, press-pending
status, current animation tracks, and before/after (0.25 s) animation snapshots for each
input test. Animation names/IDs are evidence only; no UF catch animation ID is hard-coded.
If Animator is unavailable, that is explicitly reported. There are no invented game
remotes and successful input calls remain distinct from catch activation/possession.

Tests cover delayed release duration, observed input events, animation probe data,
overlap suppression, OFF cancellation, and mouse fallback as well as the earlier
movement, clipboard and association cases. None of these mocks validate UF handlers.

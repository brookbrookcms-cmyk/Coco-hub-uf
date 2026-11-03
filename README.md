# Coco Hub UF — orb auto-catch attempts

`uf-tracker.client.luau` is a standalone client-side Luau script. It observes the
verified UF match hierarchy and provides an adjustable spherical orb and diagnostics.
When an eligible football crosses the enabled orb, it attempts a client-side move to
the ball, then restores the saved position, rotation and velocities on the next physics
step. It makes no remote calls and cannot confirm server catch validation. Movement
may be visible, rejected or corrected; this is not guaranteed catching.

Run the complete file in a Roblox client environment. It uses standard Roblox APIs,
with no downloads or external libraries. Clipboard functions are optional and are only used when Copy Result is pressed.
Delta and other executor compatibility requires live testing; it is not certified.

## Controls

The compact panel is 210 × 142 pixels.

- Drag the UF · CATCH v3 title to move the panel with mouse or touch.
- Drag or tap the slider to adjust radius from 5–100 studs, in one-stud steps.
- ON/OFF controls orb visibility, detection and catch attempts; OFF immediately restores a pending move. Lifecycle diagnostics continue.
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

Run the latest loader (the title should say `UF · CATCH v3`), leave it ON during a pass
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

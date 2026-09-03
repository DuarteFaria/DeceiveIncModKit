# GUI revamp — decided spec and handoff notes

Status: **Phase 1 done 2026-09-03.** The new window *is* `dimod_gui.py`: two
tabs, schema form, live dispatcher on a worker thread, real Save / Save &
Deploy / Start / Stop / Apply only / Restore stock, Run-tab operator actions,
the full doctor and Duplicate. `python dimod_gui.py --dry-run` keeps the
Phase 0 behaviour, logging every write and process action instead of running
it. What Phase 1 actually built, and where it deviated from the work order,
is section 13. Section 14 covers the machine-local settings added after it
(join password, scrims lobby id) and the silent failure that prompted them;
section 15 is the pre-commit review, including work that came from a
second chat and one change of it that was reverted.

This started as a menu of options; after mockups and a look at comparable
tools it became a spec. Rejected options are kept in section 10 so nobody
re-proposes them — one of them was partly reversed on request, and says so.
**Phase 2 — drift detection and the first-run panel — is the only planned
work left; see section 8.**

Read first: `dimod_gui.py`, `profile_schema.py`, `dimod.py` (the `cmd_*`
functions and `MANAGED_TRIPWIRE_KEYS`), `profiles/*.json`.

Ground rule that must survive the revamp: **all logic stays in `dimod.py`.**
The GUI drives it and renders. If the GUI needs something `dimod.py` does not
expose (save a profile, list the schema, detect drift), add a small function
to `dimod.py` and call it, rather than duplicating logic in the GUI.

---

## 1. What is wrong today

Observed in the current window and in the code:

1. **Two different "profile" concepts share one word.** The list selection
   (what you are editing) and the status-bar `profile: scoring` (what is
   deployed in the game folder, from `.deployed.json`) can differ, and nothing
   says so. Selecting `extraction` and pressing **Start** launches `scoring`.
2. **The five buttons need the CLI mental model.** `Apply` only writes files;
   `Start` does not apply; `Apply + Restart` is the one people actually want;
   `Restore stock` sits far right with no grouping. Nothing is disabled based
   on state (Stop is enabled when stopped, Start when running).
3. **Editing silently saves.** `Apply` and `Apply + Restart` call
   `_save_profile()` first, so tweaking a spinbox and pressing Apply rewrites
   the tracked JSON with no "unsaved changes" indication and no undo.
4. **Only two of the profile's knobs are editable.** The form hardcodes
   `Timing.LobbyWaitTime` / `IntroPhaseTime`. The profile JSONs also carry
   `[Extraction]` (AutoArm, AutoLoadout, Disguise, Carrier), `[Spectator]`
   (MaxSpectators), the whole `tripwire` block (GameMode, MaxPlayers,
   BotsAmount, BotsDifficulty, bIsPublic, bSandboxMode, bEnableUPnP,
   AutoShutdownEmptyMinutes, bFillWithBots), `tripwire_remove`,
   `native_modules`, `scrims_watch`, `launch_mode`. None are visible.
5. **"defaults: 90 / 19" is a hardcoded string** and the Timing box is shown
   even for profiles that have no `diconfig` section (vanilla).
6. **Mods are bare folder names** with no description and no "experimental"
   marker (DINativeLifecycle / DINativeStage2 are a one-client lab).
7. **One log pane mixes streams:** kit command output and the live UE4SS
   `[Lua]` tail, and nothing from `DIScore.log` (the actual deliverable for
   scoring). Colouring is by substring heuristics. `wrap="none"` forces
   horizontal scrolling.
8. **The operator actions are CLI-only:** `trigger-extraction`,
   `score-report`, `rescue`, `doctor`.
9. **No first-run path.** If `dipaths.FOUND` is false the GUI still opens and
   Apply writes into the `.server-not-found` sentinel. The CLI refuses via
   `require_server()`; the GUI never calls it.
10. **Nothing notices when Steam wipes the deployment.** The kit lives outside
    the game folder precisely because updates delete `Mods/`, yet the GUI
    keeps saying "profile: scoring" from `.deployed.json` after the files are
    gone.
11. **Layout is rigid.** Fixed 980x640, left column not scrollable, default
    `vista` paddings.

---

## 2. What comparable tools do (why the spec is this shape)

Looked at WindowsGSM, FASTER (Arma 3), r2modman, the UE4SS Mod Manager, and
the Vortex vs Mod Organizer 2 debate. They converge on five things, and the
kit already has all five: profiles as the unit (mod list + configs + enabled
state, one-click switch, shareable file); status + Start/Stop/Restart + live
console; a config form covering every server option with a raw-file escape
hatch; one-click mod enable/disable; a back-to-stock path and a health check.

The one lesson that changed the spec: Vortex is criticised for splitting
related settings across many screens so users forget what they set where,
while MO2 is praised for one dense view. So: **two tabs, not five**, and
nothing that belongs together is split.

The one gap the field exposes: WindowsGSM-class tools watch the deployment.
Hence **drift detection** (section 6).

---

## 3. Layout: two tabs

```
+ status strip: * Server stopped | UE4SS ok | Deployed: scoring | Scrims: - |  Doctor: ok +
+---------------+-------------------------------------------------------------------------+
| Profiles      |  [ Setup ]  [ Run ]                                                     |
|  extraction   |  -----------------------------------------------------------------------|
| >scoring *    |  Setup: description, mods, [Timing], [Extraction], [Spectator], scoring |
|  vanilla      |         toggle, TripwireServer block, Advanced, Raw JSON                |
|  + duplicate  |  Run:   operator actions (gated) + doctor results                       |
+---------------+-------------------------------------------------------------------------+
| [Kit] [UE4SS] [DIScore]                                autoscroll [x]  Clear  Copy      |
| log pane                                                                                |
+-----------------------------------------------------------------------------------------+
| [ Save & Deploy > ]   [Start|Stop]   Save   Revert                  ... Apply only/Stock |
+-----------------------------------------------------------------------------------------+
```

- **Left:** profile list. The deployed profile carries a badge; the selected
  profile carries a dirty marker when the form differs from disk. One button:
  Duplicate. Right-click opens the JSON in the default editor.
- **Centre:** a two-tab `ttk.Notebook`.
  - **Setup** is one scrollable form (section 4). Everything about a profile
    is on this one screen, in groups, so nothing is split.
  - **Run** holds the operator actions and the doctor table (section 5).
- **Bottom:** the log, full width, with stream tabs (section 7), inside a
  `PanedWindow` so it can be resized against the centre.
- **Action bar:** one primary, state-aware secondaries (section 5).

Toolkit: **ttk, no dependencies.** Theme `vista` or `clam` plus a small style
table (Segoe UI 10, Consolas 9, 8-px grid, bold section labels with a thin
separator instead of LabelFrames everywhere). Status "chips" are plain
labels with coloured text; do not build a chip widget. Remember window
geometry in a gitignored `.gui-state.json`.

Mockups in `img/gui-revamp/` predate the 2-tab decision and show five tabs;
the **content** of each is still the reference:
[Profile](img/gui-revamp/L1-profile-tab.png) +
[Server](img/gui-revamp/L1-server-tab.png) together become Setup;
[In-match](img/gui-revamp/L1-in-match-tab.png) +
[Doctor](img/gui-revamp/L1-doctor-tab.png) together become Run, with the
cuts in section 5 applied. Rendered in HTML at 1000x780; ttk will look
plainer.

---

## 4. Setup tab: schema-driven form + Raw JSON

The profile JSON is the source of truth; the form renders it from a schema.
One schema for known keys, one Raw JSON view for everything. **No generic
"render whatever is in the JSON" fallback**: the profiles are authored in this
repo, so an unknown key is a bug to surface, not a feature. Show unknown keys
as a warning line ("unknown key `foo` in tripwire, edit in Raw JSON").

Add `profile_schema.py`:

```python
SCHEMA = {
  "description":           dict(type="text"),
  "mods.*":                dict(type="modlist"),   # one checkbox per dimod.our_mods()

  "diconfig.Timing.LobbyWaitTime":  dict(type="int", min=1, max=600, default=90,
                                         label="Lobby wait (s)", needs_mod="DIConfig"),
  "diconfig.Timing.IntroPhaseTime": dict(type="int", min=1, max=600, default=19,
                                         label="Intro phase (s)", needs_mod="DIConfig"),
  "diconfig.Extraction.AutoArm":    dict(type="bool01", label="Auto-arm at match start",
                                         needs_mod="DIExtraction"),
  "diconfig.Extraction.AutoLoadout":dict(type="bool01", label="Auto-loadout for the carrier",
                                         needs_mod="DIExtraction"),
  "diconfig.Extraction.Disguise":   dict(type="enum",
                                         choices=["", "green","blue","purple","orange",
                                                  "civilian","staff","guard","technician","vip"],
                                         help="purple = technician", needs_mod="DIExtraction"),
  "diconfig.Extraction.Carrier":    dict(type="str", help="player-name substring",
                                         needs_mod="DIExtraction"),
  "diconfig.Spectator.MaxSpectators": dict(type="int", min=0, max=16,
                                         needs_mod="DINativeStage2"),
  "scrims_watch":          dict(type="bool", label="Push scores to the scrims site",
                                needs_mod="DIScore"),

  "tripwire.GameMode":     dict(type="enum", choices=["Solo","Duo","Trio"]),
  "tripwire.MaxPlayers":   dict(type="int", min=1, max=12, as_str=True),
  "tripwire.BotsAmount":   dict(type="int", min=0, max=11, as_str=True),
  "tripwire.BotsDifficulty": dict(type="enum", choices=["Easy","Normal","Difficult"]),
  "tripwire.bIsPublic":    dict(type="boolTF"),
  "tripwire.bSandboxMode": dict(type="boolTF", help="Unlock All"),
  "tripwire.bFillWithBots": dict(type="boolTF"),
  "tripwire.bEnableUPnP":  dict(type="boolTF"),
  "tripwire.AutoShutdownEmptyMinutes": dict(type="int", min=0, max=1440, as_str=True),

  "tripwire_remove":       dict(type="list[str]", advanced=True),
  "native_modules":        dict(type="multiselect", advanced=True,
                                choices=["DINativeSpectatorStage2","DINativeSpectatorStage3"]),
  "launch_mode":           dict(type="enum", choices=["normal","solo12"], advanced=True),
}
```

- Widgets: `int` Spinbox, `bool` Checkbutton, `enum` readonly Combobox, `str`
  Entry, `text` 3-line Text, `list[str]` Entry with commas, `multiselect`
  checkbuttons, `modlist` checkbuttons with a one-line description and an
  EXPERIMENTAL tag (descriptions from a `MOD_INFO` dict in `dimod.py`).
- **Value encoding must round-trip byte-for-byte.** `bool01` writes `1`/`0`,
  `boolTF` writes `"True"`/`"False"`, `as_str=True` writes `"8"` not `8`. The
  tripwire block stores strings today and must keep doing so. Preserve key
  order, `indent=2`, trailing newline (see the comment in `_save_profile`).
- `needs_mod` groups grey out (not hide) when their mod is unchecked; values
  are kept so re-checking restores them. `advanced=True` keys sit in a
  collapsed "Advanced" group at the bottom.
- Inline validation, no popups: `BotsAmount < MaxPlayers`; ranges; enum
  membership. Show the message under the field in red.
- Group order on the screen: Description, Mods, Timing, Extraction,
  Spectator, Scoring, Server (the tripwire block, with a note that
  MapRotation / bRandomizeMap are written at launch by the scrims sync and
  are not editable here), Advanced, then a **Raw JSON** expander showing the
  whole profile read-only with an "Open in editor" button.
- Valid values above come from `docs/01-server-config.md` (GameMode,
  BotsDifficulty) and `mods/DIExtraction/Scripts/main.lua` `SECURITY_LEVELS`
  (disguise). Check them there before changing.
- A `Form` class takes `(schema, profile_dict)`, builds widgets, exposes
  `dirty()` and `collect() -> dict`. Switching profiles with a dirty form asks
  Save / Discard / Cancel.

---

## 5. Actions and state

### Selected vs deployed, always visible
- Status strip: **Deployed: scoring** from `.deployed.json`. The list badges
  the deployed profile. When selection differs from deployed, a one-line
  banner at the top of Setup: *"Selected `extraction`; the server runs
  `scoring`. Save & Deploy to switch."*
- Dirty marker on the selected profile when `Form.dirty()`.

### Action bar

| Button | Does | Enabled when |
|---|---|---|
| **Save & Deploy** (primary) | save if dirty, stop, apply, launch (today's Apply + Restart, made explicit) | always |
| Start / Stop (one toggle) | `cmd_launch` / `cmd_stop`; label follows `server_pid()` | always |
| Save | write JSON only | dirty |
| Revert | reload from disk | dirty |
| "..." menu | Apply only (files), Restore stock, Open Win64 folder, Open profiles folder | always |

Never auto-save as a side effect. Apply-only while the server is running asks
"takes effect on next start. Restart now?". Restore stock keeps today's
confirmation dialog.

### Run tab, top half: operator actions
Gated on **server running AND deployed profile matches**; otherwise the group
is greyed with the reason ("start the server", "deploy `extraction` first").
Only actions an operator uses during a session:

- **extraction:** Trigger extraction [player entry], Rescue [player].
- **scoring:** Score report now, Sync rotation.
- **scrims:** one **Check** button that runs `--print-rotation` and reports
  reachable / lineup done / error into the log. Watcher pid is on the status
  strip. Nothing else: `.env` is a three-line file, edit it in an editor.

Everything else (`native-invoke`, `native-trace`, `extraction-recon`,
`arm-stage2-spectator`, `trigger-stage2`, `grant-loadout`, `disguise`,
`force-death`) **stays CLI-only.** They are developer probes, not operator
actions, and no comparable tool exposes debug hooks in its GUI.

### Run tab, bottom half: doctor
`dimod.check_*()` already return structured `Check(level, label, detail,
fix)`. Render them as rows with ok / warn / FAIL in colour and the fix line
under non-ok rows. Buttons: **Run again**, an **offline** checkbox. Run once
at startup; the status strip shows "Doctor: ok / N warnings / FAIL".

### First run / server not found
If `dipaths.FOUND` is false, show a setup panel instead of the main UI:
`dipaths.explain(dipaths.RESOLUTION)`, a **Browse...** button that writes
`server_path` into `config.json` with forward slashes, then retry.

---

## 6. Drift detection (new)

The one addition that fixes a real failure mode. Add to `dimod.py`:

```python
def deployment_drift():
    """-> [] when the game folder matches the deployed profile, else a list
    of human-readable differences: missing Mods/<m>, mods.txt enable state
    differs, DIConfig.ini differs, tripwire managed key differs."""
```

Compare what `cmd_apply` would write for the profile in `.deployed.json`
against what is on disk (`GAME_MODS` folders present, `read_mods_txt()`,
`DICONFIG` contents, `MANAGED_TRIPWIRE_KEYS` via `read_ini_values`). Do not
hash the whole game folder; only the surface `cmd_apply` owns.

Expose it three ways: a doctor check ("deployment: in sync" / "drifted: 3
differences, re-deploy"), a red **Deployed: scoring (drifted)** chip on the
status strip, and a refusal-with-hint if **Start** is pressed while drifted
("mods are missing from the game folder, use Save & Deploy"). Poll it on the
same 2-second tick as `server_pid()`, but only re-stat files (cheap); read
contents only when a size or mtime changed.

---

## 7. Log pane

- Three stream tabs: **Kit** (command output), **UE4SS** (live `[Lua]` tail,
  today's `_tail()`), **DIScore** (`DIScore.log` tail, same size-tracking
  approach, only when the deployed profile has DIScore on).
- Toolbar: autoscroll checkbox (pauses when the user scrolls up), Clear,
  Copy. Nothing else in the first cut.
- Colour by prefix, not substring: `[DIConfig]`, `[DIScore]`, `[DIExtraction]`
  dim; `ERROR` / `error:` red; lines starting `!` yellow; `applied` /
  `[ok]` / `->` green. Keep the tag names `ok/warn/err/dim`.
- `wrap="word"`. Cap each stream at 5 000 lines.
- The whole pane collapses to its toolbar via the `LOGS` disclosure
  button (added after Phase 1, section 15) and restores to the sash
  position it had.

---

## 8. Phases

**Phase 0 — DONE, accepted 2026-09-03.** `dimod_gui2.py` with `DRY_RUN =
True`: two-tab layout, selected-vs-deployed banner and badge, action bar,
schema form with dirty tracking and byte-identical collect, hidden sections,
log stream tabs with live UE4SS / DIScore tails, read-only doctor checks,
Revert. Every write and process action logs `would run: ...` instead.
Phase 0 also added a **map rotation editor** (ordered list + randomize) for
profiles without DIScore, with a note instead for scoring profiles where the
scrims sync owns the rotation. Accepted; it stays.

**Phase 1 — DONE 2026-09-03.** The work order is section 12; what was built
and where it deviated is section 13. `dimod_gui2.py` became `dimod_gui.py`,
the dispatcher runs real `dimod` calls on a worker thread, and `--dry-run`
keeps the Phase 0 behaviour for testing.

**Phase 2 — after living with it:** drift detection (section 6), first-run
panel (section 5). Nothing else is planned.

---

## 9. Implementation notes and traps

- `_run()` captures stdout with `contextlib.redirect_stdout` on a worker
  thread. That redirect is process-wide; the `busy` flag is what stops two
  actions overlapping. Keep both.
- Under `pythonw.exe` there is no console: any exception outside the queue
  path is invisible. Wrap thread bodies and `after()` callbacks so errors land
  in the Kit log.
- Polling: `server_pid()` and `pid_alive()` are ctypes on purpose; never call
  `subprocess` from `_tick()`. Drift polling must stay stat-only.
- `cmd_apply` deletes transient marker files and resets
  `MANAGED_TRIPWIRE_KEYS` to baseline before applying. `sync_scrims_rotation()`
  overwrites `MapRotation` / `bRandomizeMap` at launch; the form must not
  offer them.
- `cmd_launch` reads the **deployed** profile from `.deployed.json`, not the
  selection. This is why the banner matters.
- Profiles are tracked in git: preserve key order, `indent=2`, trailing
  newline; keep tripwire values as strings; do not reorder `mods`.
- Add to `dimod.py`: `profile_path(name)`, `save_profile(name, data)`,
  `MOD_INFO` (description + experimental flag per mod), `deployment_drift()`,
  and have `cmd_score_log` / `cmd_logs` return lines as well as print.
- Tests under `tools/`: (a) load every `profiles/*.json`, run it through
  `Form.collect()` with no edits, assert the serialised output is
  byte-identical to the file; (b) `deployment_drift()` returns `[]` right
  after `cmd_apply` against a temp game folder, and names the mod after one
  folder is deleted.

---

## 10. Rejected (do not re-propose)

- **Five tabs (Profile / Server / In-match / Scrims / Doctor).** Splits
  things that belong together; the Vortex failure mode.
- **L2, log on the right.** Leaves the form column too narrow.
- **L3, task-first cards.** No room for mid-match actions.
- **Generic JSON walker form (D2 / D3 fallback).** Unknown keys are bugs here.
- **Developer probes in the GUI.** `native-invoke`, `native-trace`, recon,
  stage2 arming, grant-loadout, disguise. CLI-only.
- **Scrims tab, general `.env` editor, API-key field.** A chip and a Check
  button. **Partly reversed 2026-09-03** (section 14): `SCRIMS_LOBBY_ID` alone
  is editable, in the Scoring group. It changes every scrim night, and it is
  not a secret. The API key and base URL stay out of the window — they are set
  once, and the key must never be displayed. Still no scrims tab.
- **Rename / delete profiles from the GUI.** Duplicate only.
- **Log search, timestamp toggle, wrap toggle.** Not in the first cut.
- **sv-ttk / CustomTkinter / PySide / web UI.** No dependency is worth it
  for "nothing too fancy".
- **Crash auto-restart.** Deferred; revisit if unattended scrims nights
  actually lose a server.

---

## 11. Phase 0 review (2026-09-03) — DONE, kept for history

All items below were applied the same day; the acceptance list in 11.5
was met and Phase 0 was accepted. Nothing here is open.

Reviewed `dimod_gui2.py` (988 lines), `profile_schema.py`, the `dimod.py`
diff (only `MOD_INFO` was added) and `tools/test_gui2_profiles.py` (6 tests,
all pass). The form model is sound and the round-trip test is the right test.
Everything below is about the Tk layer. Work through it in order; the
performance items are the ones the user actually feels.

### 11.1 Performance (scrolling and resizing feel slow)

1. **Coalesce the change handler.** `ProfileForm._changed()` runs on every
   keystroke and every checkbox trace, and each run does: read all widgets,
   `draft.collect()`, `draft.validation_errors()` again, rewrite the Raw JSON
   `tk.Text`, reconfigure the state of every field widget, then
   `on_change(...)` which calls `draft.dirty()` which calls `collect()` a
   third time. Fix: schedule the work with `after(60, ...)` and cancel the
   pending one on each new change; call `collect()` once and derive dirty
   from its result (`result != original or errors`); pass errors and dirty
   to `on_change` instead of recomputing; rewrite Raw JSON only when that
   section is open (and once on opening it); run the visibility refresh only
   when the set of checked mods changed since last time.
2. **Fix `ScrollFrame`.** The two `<Configure>` bindings feed each other and
   `canvas.bbox("all")` walks every item on every resize pixel. Fix: debounce
   both with `after_idle`/`after(30)`; in `_resize_inner` only call
   `itemconfigure` when the width actually changed; set
   `scrollregion=(0, 0, width, inner.winfo_reqheight())` instead of `bbox`.
3. **Fix wheel scrolling.** `bind_all` on canvas `<Enter>` / `unbind_all` on
   `<Leave>` breaks because Tk fires `<Leave>` on the canvas when the pointer
   moves onto any child widget, so the wheel only works over gaps. And
   `int(-event.delta / 120)` rounds precision-touchpad deltas to 0. Fix: bind
   `<MouseWheel>` once on the toplevel, route it to the canvas only when
   `winfo_containing(x, y)` is inside the scroll frame, set
   `canvas.configure(yscrollincrement=1)` and scroll by `-event.delta`
   pixels (clamp to at least ±1 when delta is non-zero).
4. **Move the two `tk.Text` widgets out of the scrolled canvas.** Text inside
   a canvas-scrolled frame is the slowest thing Tk does on resize. Raw JSON
   goes to a dialog or a third tab; the description can be a single-line
   `ttk.Entry` (the JSON value is one line anyway).
5. **Try no canvas at all.** With sections hidden (11.2) the extraction
   profile is Description, Mods, Timing, Extraction, Server and two collapsed
   cards, which likely fits in 1000x780 without scrolling. Build the form
   directly in a frame first; only wrap it in `ScrollFrame` if a profile
   actually overflows. No canvas means no resize cascade.

### 11.2 Hide sections whose mod is not checked

Replace the grey-out in `_refresh_conditions()` with per-section visibility.
Every field in a group shares one `needs_mod`, so: when the mod is unchecked,
`section.grid_remove()`; when checked, `section.grid()`. Draft values are kept
untouched either way, so nothing is lost. Vanilla then shows no Timing /
Extraction / Spectator / Scoring cards at all; extraction shows Timing and
Extraction only. Keep the Mods card always visible; it is the switch.

### 11.3 Bugs

- **Revert does nothing.** It dispatches `dimod.load_profile(...)`, which does
  not exist, and is dry-run-gated. Reverting is in-memory: rebuild the
  `ProfileDraft` from `self.profiles[name]` and reload the form. Same for
  "Open in editor" and the right-click open: `os.startfile` on a JSON file
  is a harmless read and should run live.
- **"Save before switching?" Yes leaves the profile dirty**, so the next
  switch asks again. In dry-run, either mark it clean after the simulated
  save or change the prompt to "Discard changes to X?" with Yes / Cancel.
- **Doctor panel is four static rows.** `check_platform`, `check_server`,
  `check_ue4ss`, `check_baseline`, `check_profile` are read-only: run them for
  real (they return `Check` objects) and render ok / warn / FAIL rows. Gate
  only `check_writable` (writes a probe file) and `check_scrims` (network)
  behind `DRY_RUN`, showing "skipped in dry run" rows.
- **Dispatch strings name functions that do not exist** (`duplicate_profile`,
  `load_profile`, `save_profile`, `profile_path`). Rename to the spec's
  `save_profile(name, data)` / `profile_path(name)` and add those two to
  `dimod.py` now (they are trivial and read-only apart from `save_profile`).
- **A profile with an enum value outside `choices` shows a permanent red
  error and is dirty forever**, because `validation_errors()` validates the
  initial value too. Skip validation for fields whose current value equals
  the initial value.
- **Description `tk.Text` only reacts to `<KeyRelease>`**, so a mouse paste is
  missed. Use the `<<Modified>>` virtual event (reset the modified flag after
  reading), or make it an `Entry` (11.1 item 4).
- **The "Profile" card wraps a single field.** Put Description at the top of
  the form with no card and no section header.
- **`MOD_INFO["DINativeLifecycle"]` says "read-only lifecycle observer".**
  The profile that uses it describes faction-210 login, pregame advancement
  and synthetic human accounting. Verify against
  `mods/DINativeLifecycle/Scripts/main.lua` and fix the text.

### 11.4 Make the read-only parts live so Phase 0 teaches something

`DRY_RUN` should gate writes and process control only. Reads are safe and
make the prototype feel like the real tool:

- **Tail `UE4SS.log` into the UE4SS tab and `DIScore.log` into the DIScore
  tab** using the size-tracking `_tail()` approach from `dimod_gui.py`. Both
  tabs are empty today, so the log pane cannot be judged.
- Real read-only doctor checks (11.3).
- Revert, Open in editor, Open Win64 / profiles folder: live.

Keep gated (log "would run:" only): `save_profile`, `cmd_apply`, `cmd_stop`,
`cmd_launch`, `cmd_vanilla`, `cmd_score_report`, `sync_scrims_rotation`,
`cmd_trigger_extraction`, `cmd_rescue`, `check_writable`, `check_scrims`,
the scrims `--print-rotation` check, duplicate.

### 11.5 Acceptance for this pass

- Resizing the window and dragging the sash is smooth with the extraction
  profile selected.
- Wheel scrolling works with the pointer over any field, mouse and touchpad.
- Typing in a Spinbox does not visibly lag.
- Unchecking DIExtraction removes the Extraction card; re-checking restores
  it with the same values; `tools/test_gui2_profiles.py` still passes.
- Revert restores the on-disk values without touching the disk.
- The UE4SS tab shows live lines while a server is running.


---

## 12. Phase 1 — go live (work order) — DONE, kept for history

Goal: `dimod_gui2.py` does for real what it currently logs as `would run:`,
then becomes `dimod_gui.py`. Keep dry-run available as a command-line flag
for testing; do not delete it. Everything else in the window stays as
accepted in Phase 0. Work in this order.

### 12.1 Dispatcher

Today `App.dispatch(call)` takes a **string** and logs it. Replace with
`dispatch(label, fn)` where `fn` is a zero-argument callable, and:

- `DRY_RUN` becomes `args.dry_run` from `argparse` (`python dimod_gui2.py
  --dry-run`). In dry-run, log `would run: <label>` exactly as today.
- Live: run `fn` on a `threading.Thread(daemon=True)` with stdout captured
  via `contextlib.redirect_stdout` into a `StringIO`, strip ANSI with the
  regex from `dimod_gui.py`, and push lines to the Kit log through a
  `queue.Queue` drained by `after(200, ...)`. Copy the `_run` / `_drain`
  pattern from `dimod_gui.py` lines 190-235; it is proven.
- A `busy` flag: while a dispatch runs, disable every action button (action
  bar, Run tab, Duplicate, doctor Run again) and re-enable in the `done`
  handler. The redirect is process-wide, so two concurrent dispatches would
  interleave output; refuse the second with a "busy" warning line.
- Exceptions inside `fn` are caught in the thread and logged as `ERROR:`
  in red; the `done` handler always runs. Under `pythonw.exe` nothing else
  will show them.
- After every live dispatch finishes: re-read `dimod.profiles()` and
  `dimod.load_state()`, rebuild the affected `ProfileDraft`, refresh the
  list, banner, status strip and Run-tab gating. `cmd_apply` changes
  `.deployed.json`; the window must reflect it without a restart.
- Keep the Kit-log line colouring by prefix from Phase 0.

### 12.2 Action bar

| Button | Live behaviour |
|---|---|
| Save | `dimod.save_profile(name, form.collect())`; refuse with the inline errors if `form.errors()`; then rebuild that draft from disk so dirty clears. |
| Save & Deploy | if dirty: Save first (same refusal). Then one dispatch running `cmd_stop()`, `cmd_apply(name)`, and `cmd_launch()` only if apply returned 0. |
| Start / Stop | `cmd_launch()` / `cmd_stop()` by `server_pid()`. |
| Revert | already live in Phase 0; unchanged. |
| ... Apply only | `cmd_apply(name)`. If `server_pid()`, first `askyesno`: "The server is running; this takes effect on the next start. Apply anyway?" |
| ... Restore stock | `askyesno` with the exact text from `dimod_gui.py._vanilla`, then `cmd_vanilla(False)`. |
| ... Open Win64 / profiles | already live (`os.startfile`). |

Switching profiles with a dirty form: the Phase 0 prompt becomes real. Yes
calls Save (refusing on errors and staying put), No rebuilds the draft from
disk, Cancel stays.

### 12.3 Run tab

Gating stays exactly as Phase 0 (server running AND deployed == selected AND
the deployed profile enables the mod). Live calls:

- Trigger extraction: `cmd_trigger_extraction(player or None)`.
- Rescue: `cmd_rescue(player or None)`.
- Score report now: `cmd_score_report()`.
- Sync rotation: `sync_scrims_rotation()`.
- Check scrims: `subprocess.run([dimod.python_exe(),
  tools/scrims_push.py, "--print-rotation"], capture_output=True, cwd=KIT)`
  inside the dispatch; log stderr lines, then one summary line by return
  code (0 reachable, `EXIT_LINEUP_DONE` lineup finished, else failed). Never
  log environment values.
- Doctor "Run again": run all seven `check_*` for real, including
  `check_writable` and `check_scrims(net=not offline)`, on the worker
  thread; render rows as Phase 0 does. Update the status-strip "Doctor:"
  label from the result. Run it once at startup (offline) so the strip is
  populated without a network call.

### 12.4 Duplicate

`tkinter.simpledialog.askstring` for the new name; validate
`^[A-Za-z0-9_-]+$` and that `profile_path(new)` does not exist; then
`save_profile(new, deepcopy(profiles[src]))`, reload, select the new one.
No rename, no delete (section 10).

### 12.5 Switch-over

1. `git rm dimod_gui.py`; `git mv dimod_gui2.py dimod_gui.py`. Keep the
   module docstring but drop "Phase 0 prototype" from it and from the window
   title; drop the "DRY RUN" label from the action bar unless `--dry-run`.
2. `Mod Kit.bat` already launches `dimod_gui.py`; no change.
3. README "Quick start — GUI": rewrite the paragraph. It currently says
   "tweak the timing spinboxes and mod checkboxes, then Apply + Restart" and
   "Editing anything ... and hitting Apply saves it back". New behaviour:
   pick a profile, edit on the Setup tab, **Save & Deploy**; nothing is saved
   until Save or Save & Deploy; the Run tab holds in-match actions and the
   doctor.
4. Rename `tools/test_gui2_profiles.py` to `tools/test_gui_profiles.py`
   and fix its import. Add one smoke test that constructs `App(dry_run=True)`
   and destroys it (skip if `tk.Tk()` raises, e.g. no display).
5. `.gui-state.json` is already gitignored.

### 12.6 Acceptance

- `python dimod_gui.py --dry-run` behaves exactly like Phase 0.
- Save on an untouched profile produces no git diff. Save after changing
  Lobby wait produces a one-line diff.
- Save & Deploy on `vanilla` while `scoring` runs: log shows stop, apply,
  launch in order; status strip flips to Deployed: vanilla; the Setup banner
  turns to "deployed and running".
- Apply only while running asks first; Restore stock asks first.
- Trigger extraction is disabled until `extraction` is deployed and running,
  then works and its Lua reaction appears in the UE4SS tab.
- Doctor rows match `python dimod.py doctor` output for the same machine.
- Duplicate creates the file, refuses an existing name, refuses `../x`.
- Every test in `tools/` passes; `Mod Kit.bat` opens the new window.

---

## 13. Phase 1 as built (2026-09-03)

`dimod_gui2.py` is now `dimod_gui.py` (the old 339-line window is gone) and
`tools/test_gui2_profiles.py` is `tools/test_gui_profiles.py`. Section 12 was
followed; the differences worth knowing are below.

### 13.1 The dispatcher

Two methods rather than one, because they answer different questions:

- `_run(label, fn, after)` is the machinery: worker thread,
  `contextlib.redirect_stdout`, a `queue.Queue` drained by `after(200, ...)`,
  the `busy` flag, and `after(result)` back on the UI thread.
- `dispatch(label, fn, after)` is the *gate*. In `--dry-run` it logs
  `would run: <label>` and calls `after()` anyway, so the window still shows
  the state the action would have produced. Live it delegates to `_run` and,
  when the worker finishes, re-reads `dimod.profiles()` and rebuilds the
  drafts before `after()` runs.

Two consequences of that split:

- **The doctor calls `_run` directly.** Its checks are the kit's own
  diagnostics; a dry run that could not report them would be the less useful
  mode. `check_writable` and `check_scrims` are still skipped there, and say
  so in their rows.
- `after` is zero-argument for `dispatch` and takes `fn`'s return value for
  `_run`. Only the doctor needs the value.

**Output streams line by line** instead of arriving in one block when the
command ends: a small `LogWriter` puts each completed line on the queue.
`cmd_stop` waits up to five seconds for the process to die, and watching that
happen is the difference between "working" and "hung". The thread / queue /
drain shape from the old `dimod_gui.py` is otherwise unchanged.

`_refresh_buttons` is the single place that decides what is clickable: busy
first, then dirty state, then Run-tab gating. Nothing else calls `.state()`
on an action button, so re-enabling after a dispatch cannot resurrect a
button that should have stayed grey.

### 13.2 Smaller decisions

- **Duplicate copies what is on disk**, not the dirty draft. It is not a
  second way to save unreviewed edits.
- **`_reload_profiles` never discards unsaved work.** A dirty draft outranks
  the file; everything else is rebuilt, and only when the file actually
  differs, so an action that touched no profile does not reset the form
  under the user's cursor.
- **`refused:` joined the log-colour prefixes.** It is how every gated
  `dimod` command declines, so it is the line the Run tab produces most
  often when something is not ready.
- **The scrims `--print-rotation` probe passes `CREATE_NO_WINDOW`.** The kit
  is normally started with `pythonw.exe`, where a bare `subprocess.run`
  flashes a console. Only the pusher's own stderr reaches the log; it
  redacts the key itself, and nothing from the environment is printed.
- `save_profile` prints nothing, so the GUI's closures print the filename
  they wrote. That is presentation, not logic; the write itself is still
  `dimod.save_profile`.

### 13.3 Tests

`tools/test_gui_profiles.py` has 12 tests: the 11 profile-model ones from
Phase 0, plus `WindowTests`, which builds `App(dry_run=True)` and pumps the
event loop until the startup doctor lands. Pumping rather than a bare
construct-and-destroy is deliberate: it covers the whole
worker-thread-to-queue-to-drain path, so a button naming a method that no
longer exists fails here instead of when somebody double-clicks
`Mod Kit.bat`. It skips itself when `tk.Tk()` raises.

The rest of section 12.6 was verified by driving the window headlessly
against a temp copy of `profiles/` with `cmd_stop` / `cmd_apply` /
`cmd_launch` stubbed: an untouched Save is byte-identical, an edited Save is
a one-line diff, Save & Deploy runs stop-apply-launch in order and clears
dirty, Revert never touches the disk, Duplicate creates and selects the copy
and refuses both an existing name and `../x`, a second action while busy is
refused, a worker exception lands in the log as `ERROR:` without wedging
`busy`, and Save / Discard / Cancel on a dirty profile switch behave as
specified (including refusing an invalid save and staying put). In
`--dry-run` the same sequence writes nothing at all.

**Left for the user's machine**, because they need a real server or a live
match: Start / Stop against the dedicated server, Save & Deploy end to end
with the status strip flipping, Trigger extraction with its Lua reaction in
the UE4SS tab, doctor rows matching `python dimod.py doctor`, and
`Mod Kit.bat` opening the window.

---

## 14. Machine-local settings in the form (2026-09-03)

Added after Phase 1, from two requests: there was no way to set a join
password, and the scrims lobby id could only be changed by hand-editing
`.env`. Both are settings the form can edit that are **not profile data**, and
that distinction is the whole design.

### 14.1 Why they are not profile fields

Profiles are tracked in git, so a password in one is a password in the history
of a shared repo. `dimod.py` already draws this line: `MANAGED_TRIPWIRE_KEYS`
deliberately excludes `ServerName`, `Password` and the ports, so identity keys
survive a profile switch. A profile-owned password would also mean switching
from `scoring` to `vanilla` silently changed who can join.

So: one password per machine, written straight to `TripwireServer.ini`, and
one lobby id, written to the gitignored `.env`. Neither ever reaches a profile
JSON — `tools/test_machine_settings.py` asserts that directly, because it is
the kind of thing a later refactor breaks quietly.

`AdminPassword` was offered and declined; it stays a hand-edit.

### 14.2 How it is wired

- `profile_schema.MACHINE_FIELDS` holds the two `Field`s, kept **out** of
  `FIELDS` so `ProfileDraft` cannot round-trip them into a profile. Paths are
  `ini.Password` and `env.SCRIMS_LOBBY_ID`.
- `MachineDraft` mirrors `ProfileDraft`'s contract — `set`, `dirty`,
  `validation_errors` — plus `changes()`, which returns only edited fields.
  That is what stops a password edit from rewriting an untouched profile JSON,
  and stops a plain Save from rewriting a `.env` that was already correct.
- `section_fields(group)` merges profile and machine fields for one section
  heading, so `_section` and the visibility rules see both. There is one
  window-wide `MachineDraft`, not one per profile.
- `dimod` owns the reads and writes: `read_env` / `write_env`,
  `server_password` / `set_server_password`, `scrims_lobby` /
  `set_scrims_lobby`, `scrims_env_state`. `MACHINE_IO` in the GUI maps a field
  path to that pair. `write_env` edits line-wise rather than parsing and
  rewriting, so comments and the API key are never disturbed, and it refuses a
  value containing a line break instead of corrupting the file.
- `_pending_edits` collects both halves and returns `None` to abort, so Save
  and Save & Deploy share one refusal path.
- Save & Deploy writes the machine settings **before** `cmd_apply`. Safe
  because neither key is managed: apply resets only `MANAGED_TRIPWIRE_KEYS`.
  `cmd_vanilla` does clear the password, which is correct — it restores the
  stock ini — and `_after_dispatch` re-reads the machine values so the field
  shows it rather than a stale value.

### 14.3 Changing the lobby id has a consequence

A running watcher compares `.env` against the id it started with on every tick
and **stops** rather than push a scrim's scores to the previous lobby. So the
GUI asks first when a watcher is live, and says the server needs a restart.
Declining writes nothing.

### 14.4 The silent skip that caused the bug report

The request came out of a real failure: the scrims rotation was not being
applied, and nothing said why. `sync_scrims_rotation()` returned `None`
without printing when `.env` was missing — indistinguishable, from the
outside, from a server ignoring its rotation. There was no `.env` on the
machine at all.

Two fixes, both kept:

- Past the `scrims_watch` check, the profile has *asked* for scrims, so a skip
  is a misconfiguration and is now a loud `! rotation NOT synced` with the
  reason. It returns `False`, not `None`, so a caller can tell "nothing to do"
  from "could not".
- The Scoring group carries a status line: `.env` missing, or which of
  `SCRIMS_API_KEY` / `SCRIMS_BASE_URL` / `SCRIMS_LOBBY_ID` are unset.
  **Presence only** — no value from `.env` other than the lobby id is ever
  displayed.

---

## 15. Review before the first commit (2026-09-03)

Two more changes arrived from a separate chat on the same day, undocumented.
Reviewed against the running tree before anything was committed.

**Kept:**

- **The log pane collapses.** The `LOGS` label in its toolbar is now a
  disclosure button. Collapsing hides the stream tabs, gives the pane weight 0
  and moves the sash down to fit the bare toolbar; expanding restores the exact
  sash position from before. Verified to round-trip (469 → collapsed → 469).
  The state is not remembered in `.gui-state.json`; nobody has asked for that.
- **The Run tab scrolls.** It sits in a `ScrollFrame` like Setup, so a long
  doctor list no longer pushes the operator actions off the bottom.

**Removed:**

- **Doctor rows filtered by the selected profile's mods.** `_collect_checks`
  tagged each row with a mod and `_render_doctor` dropped rows whose mod the
  *selected* profile did not enable, re-rendering on every switch. The checks
  describe the machine and the **deployed** profile, so this hid live problems:
  with `scoring` deployed and its `.env` broken, clicking `vanilla` in the
  list made the scrims FAIL rows vanish and the status strip turn green. It
  also contradicted the label above the rows and the §12.6 acceptance rule
  that rows match `python dimod.py doctor`. There is no correct version of the
  filter to keep: `check_scrims` already answers "not a scoring profile -
  skipped" when a non-scrims profile is deployed, and `check_profile` only
  lists the deployed profile's mods — so the only rows it could ever hide were
  relevant ones. `_render_doctor` is back to rendering every row, with a
  comment saying why.

Also fixed in the same pass: the second chat's lines came in LF; the working
copy is CRLF per `.gitattributes`, and mixed endings are the exact thing that
file exists to end.

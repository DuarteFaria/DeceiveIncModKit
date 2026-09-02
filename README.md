# Deceive Inc. — Dedicated Server Mod Kit

Everything discovered about modding the Deceive Inc. dedicated server, plus a
manager to switch between configurations and get back to stock cleanly.

The kit lives **outside** the game folder on purpose — a Steam update wipes
anything inside `steamapps\common`. Nothing here is authored in the game
directory; `dimod.py apply` deploys into it, `dimod.py vanilla` takes it back out.

---

## Quick start — GUI

Double-click **`Mod Kit.bat`**, or:

```bash
python dimod_gui.py
```

Pick a profile on the left, tweak the timing spinboxes and mod checkboxes, then
**Apply + Restart**. The right pane live-tails the UE4SS log, so you can watch
`LobbyWaitTime: 90 -> 20 [ok]` scroll past as it applies. Status across the top
shows whether the server is up, whether UE4SS is installed, and which profile is
active.

Editing anything in the left panel and hitting Apply saves it back into the
profile JSON — the kit stays the source of truth.

## Quick start — CLI

```bash
cd C:\Users\Duarte\DeceiveIncModKit

python dimod.py status                    # what's deployed and running
python dimod.py list                      # available mods and profiles
python dimod.py restart scoring           # stop, apply, launch, inject
python dimod.py logs 40                   # tail the UE4SS log
python dimod.py apply vanilla             # back to stock gameplay
```

`apply` only writes files. The server reads them at startup, so use
`restart <profile>` to actually change a running server.

---

## Profiles

| Profile | What it does |
|---|---|
| `extraction` | The carrier-extraction game mode. See [docs/12](docs/12-extraction-mode.md). |
| `native-spectator-stage2` | Death-spectator + freecam. Join as a normal player, deploy, die; then `trigger-stage2` for freecam. |
| `scoring` | Per-player ranked MP scoring. See [docs/13](docs/13-ranked-scoring.md). |
| `vanilla` | Stock gameplay. Mods off, normal map rotation, public. |

The research and probe profiles from the discovery phase were removed in the
2026-09-01 cleanup, along with the mods they drove. What they established is
written up in `docs/`; the profiles themselves were single-use.

### Spectator status

**What works today (2026-09-01):** the *deploy-then-spectate* flow. Join
`native-spectator-stage2` as a normal player (do **not** arm anything), pick an
agent, deploy, then die to a bot. The untouched client drops into the game's
native follow-spectator — spectator HUD plus `A` / `D` cycling and following
living agents. This is stable; the server stays up. `python dimod.py
trigger-stage2` additionally gives a one-way `DebugFreecam` free-roam view.

**What does not work, and why:** returning from freecam to follow. Native
follow-spectating is *pawn-less* — the game creates no `DISpectatorPawn`, so its
native free-move (`CheatSpectateFreeMove` / `DIFreeSpectator`) has no instance to
drive. That free-move belongs to the dedicated-spectator (faction-210) pawn,
which only exists on the login path — and that path, while it does get the
untouched client out of the agent-select menu, runs an unstable zero-combat-player
match (intermittent native crash in bot faction assignment). Do **not** kill a
player with `force-death` (disabled): a raw `SetHealth(0)` kill trips the human
killcam into a status-3 exit; only a real bot kill enters spectating cleanly.

**Reaching a second human is blocked by CGNAT** on this host, so the
additional-spectator-connection target is on hold. See the
[`spectator feasibility and implementation plan`](docs/08-native-spectator-plan.md)
for the full route history and the remaining native option.

Profiles are plain JSON in `profiles/`. Copy one and edit:

```json
{
  "description": "shown by dimod list",
  "mods":     { "DIConfig": true, "DIExtraction": false },
  "diconfig": { "Timing": { "LobbyWaitTime": 30 } },
  "tripwire": { "MapRotation": "Tutorial", "bIsPublic": "False" },
  "tripwire_remove": ["MapRotation"]
}
```

---

## Getting back to stock

Two different things, deliberately kept separate:

```bash
python dimod.py apply vanilla    # mods off, keeps your ServerName/Password/ports
python dimod.py vanilla          # hard reset: restores the original ini too
python dimod.py vanilla --full   # ...and removes UE4SS entirely
```

Prefer `apply vanilla` for day-to-day. The bare `vanilla` command restores
`baseline/TripwireServer.ini.original`, which reverts your hand-edits — it
saves a timestamped copy into `baseline/` first, so nothing is lost.

---

## Mods

| Mod | Purpose |
|---|---|
| `DIConfig` | Applies lobby wait, intro duration, and the spectator-slot cap from `DIConfig.ini`. |
| `DIExtraction` | The carrier-extraction mode: phase advance, loadout, disguise, teleport. |
| `DINativeStage2` | Drives the death-spectator freecam route. |
| `DINativeLifecycle` | Read-only lifecycle observer; part of the verified spectator profile. |
| `DIScore` | Read-only ranked MP scoring from the game's own XP event counters. |

---

## Documentation

| File | Contents |
|---|---|
| [docs/01-server-config.md](docs/01-server-config.md) | Full `TripwireServer.ini` reference — all ~31 keys with defaults |
| [docs/02-community-balance.md](docs/02-community-balance.md) | The official balance profile system and its limits |
| [docs/03-console-variables.md](docs/03-console-variables.md) | Game console variables with their real help text |
| [docs/04-ue4ss.md](docs/04-ue4ss.md) | UE4SS setup, why injection is required here |
| [docs/05-findings.md](docs/05-findings.md) | Object-graph discoveries — the actual values and where they live |
| [docs/06-dead-ends.md](docs/06-dead-ends.md) | The pak encryption investigation. Read before repeating it. |
| [docs/07-whats-moddable.md](docs/07-whats-moddable.md) | Practical reflection/native modding tiers and their limits |
| [docs/08-native-spectator-plan.md](docs/08-native-spectator-plan.md) | Authoritative spectator feasibility verdict, current capability matrix, blockers, and implementation gates |
| [docs/09-native-stage0.md](docs/09-native-stage0.md) | Reproducible native workspace, hashes, safety boundary, and rollback |
| [docs/10-native-stage1.md](docs/10-native-stage1.md) | Diagnostic hooks, dependencies, evidence workflow, and rollback |
| [docs/11-native-stage2.md](docs/11-native-stage2.md) | Historical Stage 2 route log and rollback; not a finished feature |

---

## Safety notes

- **Server only.** Nothing here touches the game client. The client runs
  EasyAntiCheat; modifying it risks a ban. The dedicated server is launched
  directly via `DeceiveIncServer-Win64-Shipping.exe`, bypassing the EAC
  bootstrapper entirely, so no anti-cheat is involved.
- **Steam updates** overwrite the game folder. After one, re-run
  `dimod.py apply <profile>`. UE4SS itself may need reinstalling.
- Blueprint function calls from Lua can hard-crash the server - `pcall` does
  not catch it. See docs/05.
- Applying a profile resets manager-owned gameplay keys to their stock baseline
  first. ServerName, Password, ports, and other identity/network settings are
  preserved, so profile settings cannot leak into the next profile.

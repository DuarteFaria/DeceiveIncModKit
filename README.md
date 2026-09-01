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
python dimod.py restart tutorial-explore  # stop, apply, launch, inject
python dimod.py logs 40                   # tail the UE4SS log
python dimod.py apply vanilla             # back to stock gameplay
```

`apply` only writes files. The server reads them at startup, so use
`restart <profile>` to actually change a running server.

---

## Profiles

| Profile | What it does |
|---|---|
| `vanilla` | Stock gameplay. Mods off, normal map rotation, public. |
| `fast-lobby` | Normal maps, 10s lobby instead of 90s, 5s intro instead of 19s. |
| `tutorial-explore` | Tutorial map as free-roam sandbox, scripted doors removed. |
| `solo-12` | 12-player Solo via a memory-only server patch; the EOS browser may still show 8. |
| `death-spectate` | Test the game's normal death-spectator flow. |
| `native-spectator-stage0` | Experimental server-only no-op native loader; no spectator behavior. |
| `native-spectator-stage1` | Experimental server-only exit and lifecycle diagnostics; no exit suppression. |
| `native-spectator-stage2` | Experimental one-client lab: login-time faction-210 spectator plus a guarded one-shot native lobby-readiness hook. |
| `killprobe` | Safely inventory elimination functions; does not kill while `DumpOnly=1`. |
| `loot` | Inventory actors actually produced by every world spawn point. |
| `discovery` | Research mode - runs the object-graph probes and writes dumps. |

### Spectator status

No spectator profile is production-ready. `native-spectator-stage2` is a manual,
one-client prototype. Login-time faction 210 is recognized by the untouched
client, and the new server-only readiness hook removes the zero-combat-player
lobby stall without entering the agent-deployment path; its first end-to-end
test is pending. Controllable freecam works, while reliable switching between
free movement and a camera that follows the selected agent remains incomplete.
Two simultaneous spectators and extra spectator capacity are also unverified.
The final target prefers additional spectator connections; consuming normal
player slots is the accepted fallback. See the
[`spectator feasibility and implementation plan`](docs/08-native-spectator-plan.md)
before running the legacy experiment profiles.

Profiles are plain JSON in `profiles/`. Copy one and edit:

```json
{
  "description": "shown by dimod list",
  "mods":     { "DIConfig": true, "DIUnstick": false },
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
| `DIUnstick` | Removes the 14 scripted tutorial sliding doors so the map is traversable. |
| `DIFree` | Read-only probe of objects created by the normal death-spectator flow. |
| `DIKill` | Probe for a proper server-side elimination call; safe by default (`DumpOnly=1`). |
| `DILoot` | Tallies every actor produced by world spawn points during a match. |
| `DIProbe` | Research. Deep-dumps target assets to `DIProbe_dump.txt`. |
| `DITut` | Research. Tutorial-specific inspection. **Has crashed the server** — see docs/05. |

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

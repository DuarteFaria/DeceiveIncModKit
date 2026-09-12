# Deceive Inc. — Dedicated Server Mod Kit

Everything discovered about modding the Deceive Inc. dedicated server, plus a
manager to switch between configurations and get back to stock cleanly.

The kit lives **outside** the game folder on purpose — a Steam update wipes
anything inside `steamapps\common`. Nothing here is authored in the game
directory; `dimod.py apply` deploys into it, `dimod.py vanilla` takes it back out.

**WARNING**

This is a research-only project used as a playground to learn about modding as someone who has never touched game dev before.
A lot of LLMs were used to help me pave my way, so I'm aware that the quality produced is not good at all.
My main goal was to test if modding was possible, what was possible to do, and have fun along the way.

---

## First run on a new machine

```bash
python dimod.py doctor
```

That is the whole setup check. It reports the game path and how it was found,
whether the server executable and UE4SS are present, whether the mod can
actually write its logs, which profile is deployed, and — for a scoring profile
— whether the scrims API answers. Exit status is non-zero only for problems that
will stop the kit working, so it is safe to script.

**The game path is detected, not configured.** The kit reads Steam's own
library list, so a server on `D:` is found without being told. If detection
fails, either is enough:

```bash
set DI_SERVER_PATH=D:\SteamLibrary\steamapps\common\Deceive Inc. Dedicated Server
```

or copy `config.json.example` to `config.json` and set `server_path`. Use
forward slashes there — a lone backslash is not legal JSON. `python dipaths.py`
prints what was resolved and from which source.

A path that exists but has no server executable in it is ignored rather than
trusted, and `doctor` names it, so a stale setting cannot half-work.

**Requirements:** Windows (the dedicated server and UE4SS are Windows-only),
Python 3.9+, and UE4SS installed into the server's `Win64` folder — see
[docs/04-ue4ss.md](docs/04-ue4ss.md).

**Write access matters.** The mods write their logs and reports next to the
server executable, under `Program Files` on a default install. Without write
permission there, Windows redirects the writes to a per-user `VirtualStore` and
the scrims watcher looks for a report that is not there. `doctor` probes this
directly rather than assuming.

---

## Quick start — GUI

<img width="1390" height="839" alt="image" src="https://github.com/user-attachments/assets/578cd9f9-47a3-4175-bd3b-4d5285a1ca93" />


Double-click **`Mod Kit.bat`**, or:

```bash
python dimod_gui.py
```

Pick a profile on the left and edit it on the **Setup** tab — description, mods,
timing, the extraction and spectator options, and the `TripwireServer.ini` block
the profile owns, each group appearing only when the mod that reads it is
checked. **Save** writes the JSON; **Save & Deploy** saves, stops the server,
applies the profile and starts it again. Nothing is written until you press one
of those two: the form is a draft, a changed profile is marked `*` in the list,
and **Revert** throws the draft away.

Two fields on that tab are **not** profile data, because profiles are tracked in
git and shared: the join password (Server group) goes straight to
`TripwireServer.ini`, and the scrims lobby id (Scoring group) goes to `.env`.
Both belong to this machine and survive profile switches. Save writes them along
with the profile, and only when you actually changed them. Changing the lobby id
while a scrims watcher is running stops that watcher — the window asks first.

The **Run** tab holds the actions that only make sense mid-session — trigger an
extraction, rescue a player, ask for a score report, sync the map rotation — each
greyed with the reason until the profile that provides it is both deployed and
running. Underneath them the doctor runs the same checks as `python dimod.py
doctor`, so a broken install explains itself in the window.

The status strip separates the profile you are *editing* from the one that is
*deployed*, which is the distinction the CLI makes and the old window did not.
The log pane at the bottom has three streams: kit command output, the live UE4SS
`[Lua]` tail (watch `LobbyWaitTime: 90 -> 20 [ok]` scroll past as a profile
applies), and `DIScore.log` when the profile is a scoring one. Click **LOGS**
to collapse the pane to its toolbar when you want the form.

`python dimod_gui.py --dry-run` opens the same window with every write and every
start/stop replaced by a log line. It is the safe way to look around.

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
| `vault-assault` | 3v3 asymmetric vault defense with player bots retained and ambient NPCs removed. See [docs/15](docs/15-vault-assault.md). |
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
  "tripwire": { "MapRotation": ["Hardsell", "Silverreef"], "bIsPublic": "False" },
  "tripwire_remove": ["AutoShutdownEmptyMinutes"]
}
```

`MapRotation` must be a **list**, one entry per map, in play order. A
comma-separated string is taken by the server as a single map name that matches
nothing, and it falls back to its default pool.

`tripwire_remove` deletes a key outright, for the rare case where the key's
absence is not the same as any value it could hold. You rarely need it: applying
a profile already resets every key in `MANAGED_TRIPWIRE_KEYS` to
`baseline/TripwireServer.ini.original`, so a key the baseline does not carry is
gone anyway. Listing a key in both blocks is a contradiction — `tripwire` wins
and `apply` says so.

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
| `DIExtraction` | Carrier-extraction and 3v3 vault-assault modes: phase control, loadout, roles, timers, teleport. |
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
| [docs/12-extraction-mode.md](docs/12-extraction-mode.md) | Carrier extraction and the shared server-side objective primitives |
| [docs/15-vault-assault.md](docs/15-vault-assault.md) | 3v3 vault-assault prototype, rules, configuration, and test checklist |

The `vault-assault` profile is persistent: after the shipping server exits at
the result screen—or when the final human leaves an active match—its local
supervisor starts a fresh lobby automatically. Use `python dimod.py stop` to
stop both processes.

---

## Safety notes

- **Server only.** Nothing here touches the game client. The client runs
  EasyAntiCheat; modifying it risks a ban. The dedicated server is launched
  directly via `DeceiveIncServer-Win64-Shipping.exe`, bypassing the EAC
  bootstrapper entirely, so no anti-cheat is involved.
- **Steam updates** overwrite the game folder. After one, re-run
  `dimod.py apply <profile>`. UE4SS itself may need reinstalling.
- **The game's own binaries are not in this repo.** Neither the server
  executable nor `ue4ss.dll` is committed - they are not ours to redistribute -
  so `baseline/` holds only text on a fresh clone. Nothing in the kit reads
  them; they were a manual rollback net for a binary patch that never happened
  (the Solo-12 patch only ever touched memory), and Steam's *verify integrity
  of game files* restores the executable anyway. Bring your own copies in if you
  want the net, then `python tools/verify_baseline.py` to check them against
  the committed `manifest.sha256`.
- Blueprint function calls from Lua can hard-crash the server - `pcall` does
  not catch it. See docs/05.
- Applying a profile resets manager-owned gameplay keys to their stock baseline
  first. ServerName, Password, ports, and other identity/network settings are
  preserved, so profile settings cannot leak into the next profile.

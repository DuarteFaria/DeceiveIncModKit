# Object-graph findings

Everything here was read from the **live server process** via UE4SS, not from
unpacked assets. The pak is encrypted and stayed that way (docs/06) — none of
this required breaking it.

Raw dumps: `DIProbe_dump.txt`, `DITut_dump.txt` in this folder.

---

## 1. Lobby wait time — SOLVED

```
PregameLobbyMapData /Game/Levels/LVL_SharedLevels/LVL_PreGameLobby/
    DA_PregameLobbyMapData_PregameLobby
        PregameLobbyPhaseData
            DefaultPhaseDuration = 90
```

Writable at runtime, verified by read-back:

```
[DIConfig] LobbyWaitTime: 90 -> 25  [ok]
```

Set via `DIConfig.ini` → `[Timing] LobbyWaitTime`.

### The write has to win a race

This is the subtle part, and it cost a round of "it says `[ok]` but nothing
changed".

`ADeceiveIncMatchGameState::SetCurrentPhaseInfoFromMapData` **copies**
`DefaultPhaseDuration` out of the data asset when the pregame phase starts.
After that instant the running match holds its own copy — writing the asset
succeeds, reports `[ok]`, and changes nothing until the next map cycle.

The original setup lost that race every time:

```
12:50:36.783   SetCurrentPhaseInfoFromMapData :: Pregame   <- reads 90
12:50:38       Starting mod 'DIConfig'                     <- 1.2s too late
                                                              + 15s apply delay
```

Two changes fixed it:

- `inject.py` no longer sleeps a fixed 8s. It watches the process's module
  count and injects once loading settles (~2.8s) — early enough to beat the
  phase, late enough that the AOB scan still finds an initialised engine.
- `DIConfig` applies **immediately** at mod load, then every 0.5s for 30s to
  win the race, then drops to a 30s loop to survive map changes.

Result:

```
12:54:09       LobbyWaitTime: 90 -> 15  [ok]
12:54:13.842   SetCurrentPhaseInfoFromMapData :: Pregame   <- 4s of margin
```

**General rule for this codebase:** phase data is snapshotted at phase start.
Any override of a phase duration must be in place before the phase begins.

### Confirmed by measurement

Both settings verified end to end against the server log, timed from
`ServerSelectAgent` to the next `OnNewGamePhaseSet`:

```
06:20.887   AGENT SELECTED
06:35.750   POSING_SPY_INTRO     14.86s   (LobbyWaitTime = 15)
06:41.217   VAULT_LOCKED          5.47s   (IntroPhaseTime = 5)
```

Stock for comparison: ~90s pregame, ~20s intro.

### The client HUD lies

The in-game lobby clock still counts down from **90** even when the server is
running 15. The HUD reads the *client's* copy of
`DA_PregameLobbyMapData_PregameLobby`, which a server-side mod cannot touch.

It is cosmetic. The phase transition is what actually governs, and it honours
the server value. **Never verify a timing change by looking at the on-screen
clock** — measure `ServerSelectAgent` to the next `OnNewGamePhaseSet` in
`DeceiveInc.log` instead.

### How to measure it correctly

```bash
grep -oE "\[[0-9.:-]+\].*(ServerSelectAgent_Implementation\[860\]|ESpyGamePhase::[A-Z_]+)" \
  DeceiveInc/Saved/Logs/DeceiveInc.log | tail -10
```

Two traps, both of which produced a wrong answer during this work:

- **Check for reconnects.** A player leaving and rejoining creates a second
  `ServerSelectAgent`. Measuring from the first one spans the whole gap and
  yields a nonsense duration (109s, in the case that misled us).
- **Use `ServerSelectAgent`, not `Match State Changed ... InProgress`.** The
  latter only fires for the *first* selection in a session, so it is not a
  reliable anchor.

**Caveat:** the tutorial map logs `P:[]` — no pregame lobby data — so this has
no effect there. Regular maps only.

## 2. Intro / posing phase — SOLVED

`SpyGameModeMapData.IntroPhaseData.DefaultPhaseDuration`, one asset per map:

| Asset | Default |
|---|---|
| Hardsell, Silverreef, Diamondspire, FragrantShore, SoundEclipse | 19 |
| `DA_SpyGameModeMapData_Default` | 5 |
| `DA_SpyGameModeMapData_Tutorial`, `_TrainingRange` | 5 |

Set via `[Timing] IntroPhaseTime`. Applied to all 8 assets.

## 3. Tutorial map — SOLVED, and it needs no mod at all

`DA_MapData_Tutorial` exists and **is already in the playable pool**. One line:

```ini
MapRotation=Tutorial
```

Confirmed:
```
PickMap: ShortName:Tutorial MapAssetId:MapData:DA_MapData_Tutorial Index:0
Bringing World /Game/Levels/LVL_Tutorial/LVL_Tutorial up for play
Took 0.98 seconds to LoadMap(/Game/Levels/LVL_Tutorial/LVL_Tutorial)
```

`MapData` assets carry only `MapFileName` + `AssetType` — there is no
"is playable" flag on the asset. The 7-map rotation everyone sees is just what
`bRandomizeMap` picks from, not the limit of what's allowed.

Full list of 10: Hardsell, Hardsell_Day, Silverreef, Diamondspire,
FragrantShore, FragrantShore_Night, SoundEclipse, **Tutorial**,
**TrainingRange**, **PrivateLobby**.

## 4. Tutorial script — NOT recoverable

The map loads with all its content: 14 scripted sliding doors, keycard
printers, healing stations, ammo dispensers, breadcrumbs, fake powerup chests,
vault door and terminal, and the named scripted NPCs (Amber, Ann, Curtis,
Douglas, Gina, Monique, Olivia, Peter, Ronald, Susan, Timothy, Wendy).

Both Level Blueprints are instantiated server-side: `Flow_Tutorial_C` and
`LVL_Tutorial_C`. But `Flow_Tutorial_C` exposes:

```
functions:   SetPlayerHUDVideoTips
properties:  UberGraphFrame
```

One function, zero state variables. All logic is compiled inside the ubergraph
where reflection cannot reach it. There is no step counter to read and no
entry point to call, so the original sequence cannot be driven from outside.

Three further blockers:

- Server runs `BP_DeceiveIncBaseGameMode_C`, not `EDIGameRuleset::Tutorial`
- The teaching layer is client HUD (`HUD_TutorialTip_C`,
  `HUD_TutorialTip_Video_C`, `HUD_TutorialIntroSubtitles_IRIS_C`,
  `STR_TutorialTips`) driven by the client's own tutorial mode
- Authored for standalone play, so almost certainly unreplicated

**Workaround:** `DIUnstick` removes the doors, turning the map into a free-roam
sandbox. The course order is readable from the door names:

```
01_Enter_CoverCourse  →  02_Exit_CoverCourse  →  03_Exit_GreenRoom
  →  04_Enter_GadgetRoom  →  05_Enter_SecurityRoom
  →  06_ExitVaultTerminalRoom  →  07_Enter_MainLobbyFromStairs
```

Plus `LobbyBunkerDoor_Left_0` and `LobbyBunkerDoor_DoubleDoor` at the start —
`Left_0` is the one that traps you at spawn.

## 5. Room item spawns — Tier 1 ruled out, Tier 2 open

Settled by `DISpawn` against a live bot match (`DISpawn_dump.txt`). The spawn
points carry **no configuration at all**:

```
BP_ObjectSpawn_Generic_C   x1010   (SoundEclipse; FragrantShore had 471)
  [BP_ObjectSpawn_Generic_C]  SM_Hackable_LVL2  [ObjectProperty]
  [ObjectSpawn]               SpawnedActor      [ObjectProperty]
```

Sibling classes (`_BigLootable` x13, `_LAFBoxes` x8, `_VaultPrinter` x32,
`BP_Small_Object_Spawn_C` x2) are the same shape: a mesh or nav ref, plus
`SpawnedActor`.

**`SpawnPointType` and `CustomPossibleObjectsToSpawn` do not exist.** They were
predicted in an earlier version of this doc from type names seen in the binary;
the live graph has neither. Selection happens in
`ObjectSpawningManager::HandleAllRoomsSetup` and compiled blueprint, out of
reflection's reach. **There is no property to write, so Tier 1 cannot solve
this.**

What is left:

- **Tier 1, density only** — `ObjectSpawningManager.FillingObjectsMaxWeightFactor
  = 45.0` changes how much gets placed, not what.
- **Tier 2** — `SpawnedActor` is a live reference to the placed item, so points
  can be inventoried, cleared and repopulated after the fact. `DILoot` does the
  inventory half.
- **Tier 3** — hook `ObjectSpawningManager::HandleAllRoomsSetup`.

Only one function is exposed on the spawn points themselves:
`ObjectSpawn::UpdateConnectedRoomsReference` — which implies a room association
exists internally, but it is not a reflected property, so "guard room" versus
"staff room" is not readable directly. Position is the likely fallback.

## 6. Suspicion system — Tier 1 confirmed writable surface

```
DA_NPCSuspiciousness_Default
    NPCSuspiciousness  (5 entries)
        RankPercentage = 1.0 / 2.0 / 5.0 / 15.0 / 20.0
NPCBehaviorDefault (x665 live NPCs)
    ChancesToInteract = 28.0
```

All plain floats, so all Tier 1. Untested as writes so far.
Plus `SpyCheatsComponent:CheatToggleSpySuspiciousSystem` /
`CheatToggleSpySuspiciousSystemSrv` — a server-side toggle worth investigating.

## 7. Player count / solo lobbies — no property exists

`DIAllowedGameModesHandler` reflects **zero properties** and one function,
`GetAllowedGameModes()`. `MaxPlayers` in `TripwireServer.ini` is the only
Tier 1 control. 12-player solo would be a Tier 3 hook, not a setting.

---

## Hard-won lessons

**Blueprint calls can hard-crash the server, and `pcall` will not save you.**
Calling `ChooseDoor()` / `BPI_SlidingDoor_Open()` on a door killed the process
outright. `BPI_SlidingDoor_Open` exists on `BP_PlayerStart_Tutorial_C`, *not*
on the door class. Verify a function exists on the exact class before calling,
prefer stock `AActor` functions, and log *before* each call so a crash names
the culprit.

**`ForEachProperty` only walks a class's own properties.** Walk
`GetSuperStruct()` up the chain or you will conclude an object is nearly empty.
This cost a full iteration.

**Struct and array values need explicit recursion** — `StructProperty:GetStruct()`
and `ArrayProperty:GetInner()`.

**Don't infer the possible from the observed.** I concluded the tutorial map
was unavailable because seven map names appeared in old logs. It was available
the whole time; one ini line proved it. Test the cheap thing before theorising.

**Buffered output loses the crash.** DISpawn v1 buffered 300 lines and hard-
crashed the server at t+60s, writing nothing at all. UE4SS crashes are not
catchable by `pcall`, so any probe of unfamiliar territory must append and close
per line, and must write the property name and type *before* reading the value.
v2 did exactly that and completed both passes.

**A silent property is not an empty one.** DICensus printed nothing for
`BP_ObjectSpawn_Generic_C` and it was tempting to read that as "no data". It
only rendered *scalar* values, and every property on that class is an object
reference. The heuristic hid the target it was built to find. Dump the type
alongside the value, always.

## 8. Spectators — both modes proven, hybrid transition incomplete

The game ships a substantial first-party spectator system: custom
`DISpectatorPawn` / `DIFreeSpectator` pawns, spectator input contexts, target
cycling RPCs, HUD assets, a reservation beacon, and debug/free-movement code.

The current evidence is stronger than the original reflection-only probe:

- natural death creates a working follow spectator with HUD and `A` / `D`
  cycling through living agents;
- a game-created `DebugFreecam` can be made controllable by the untouched
  client and is ignored by bots;
- Route 27 switches one naturally dead player into freecam and back while the
  server controller remains in `Spectating`;
- after the return, `A` / `D` reaches the server and selects valid live actors,
  but the client camera remains fixed instead of following them.
- native inspection shows `SetupAsDedicatedSpectator()` assigns the reserved
  `FactionID=210`; `GetIsDedicatedSpectator()` checks for that exact value. The
  earlier experiment incorrectly replaced it with `255`, invalidating its own
  dedicated-spectator state;
- the shipped freecam settings path has a real collision-profile toggle. This
  confirms a noclip mechanism exists, although server-to-client activation is
  not yet proven.

This makes spectator mode a credible native reverse-engineering project, not a
configuration feature and not a finished mod. The authoritative capability
matrix and next gates are in
[`08-native-spectator-plan.md`](08-native-spectator-plan.md); the route history
is in [`11-native-stage2.md`](11-native-stage2.md).

### Direct spectator joining is still closed

`DeceiveIncGameSession.MaxSpectators` is writable and defaults to 2. It is a
separate engine spectator limit, but it only applies after a connection is
classified as a spectator; it does not convert a normal player by itself.

The stock client has no spectator button. Steam/EAC successfully forwarded the
tested startup URL, but Deceive Inc. discarded it in favor of its startup map:

```
LogInit: Command Line:  -nosplash <server>:7777?SpectatorOnly=1?Password=<redacted>
LogNet:  Browse: /Game/Levels/LVL_StartupClient?Name=Player
```

Retrying URL syntax is not useful. For the current prototype a player must join,
select an agent, and enter the natural death-spectator flow. Extra connections
such as `8 players + 2 spectators` additionally require native login,
reservation, and EOS-capacity work.

**Never launch the client's shipping executable directly to force a URL.** That
bypasses the client-side EasyAntiCheat path. The client remains unmodified in all
supported experiments.

### Lesson

**Strings and reflected names prove that code was compiled in, not that its
transition is reachable.** Confirm behavior against the live controller,
PlayerState, acknowledged pawn, client input, and camera before promoting a
route from experiment to feature.

## 9. Player count - stock mode caps and the Solo-12 runtime patch

`MaxPlayers` in `TripwireServer.ini` is not the cap. The server reads it, then
clamps it against a **per-game-mode maximum**:

```
Init            :: MaxPlayers:12
ClampIntSetting :: Name:MaxPlayers Value:12 Clamped:8 Range:1,8
FactionPlan     :: TeamSize:1 NumTeams:8 MaxPlayers:8
```

Measured by restarting the server once per mode and reading the startup log:

| `GameMode=` | Enum | TeamSize x NumTeams | Cap |
|---|---|---|---|
| `Solo` | 2 | 1 x 8 | **8** (range 1,8) |
| `Duo` | 3 | 2 x 5 | **10** (range 1,10) |
| `Trio` | 4 | 3 x 4 | **12** (no clamp) |
| `CustomMatch` | 4 | 3 x 4 | 12 (resolves to Trio) |

So **12 players needs `GameMode=Trio`**, and it is pure config. Profiles:
`trio-12`, `duo-10`, `solo-8`.

`EDIGameMode` in full: None, Solo, Duo, Trio, CustomMatch, PrivateLobby,
Training, Tutorial, LimitedTime1, LimitedTime2, Count.

### Dead ends checked first

- **`MaxPlayers` is not reflected.** `AGameSession` exposes only `MaxSpectators`
  (confirmed writable — DIConfig moved it 2 -> 4). `TripwireServerSettings` has
  zero live instances; `TripwireDedicatedServerManager` exposes zero functions.
  No UE4SS route exists.
- **`net.MaxPlayersOverride=12`** in `Engine.ini [SystemSettings]` is accepted
  (`LogConfig: Setting CVar [[net.MaxPlayersOverride:12]]`) and has **no effect** —
  Tripwire's clamp is independent of the engine cvar. Reverted.

### Why 12-player Solo needs a server-code patch

The clamp maximum is selected by a branch chain at the `MaxPlayers` call site:

```
0x10dbe62   41 b9 0c 00 00 00    mov r9d, 12
0x10dbe6a   41 b9 0a 00 00 00    mov r9d, 10
0x10dbe72   41 b9 08 00 00 00    mov r9d, 8     <- Solo
0x10dbe7c   lea rdx, "MaxPlayers"
0x10dbe8b   41 b8 01 00 00 00    mov r8d, 1     <- min
```

Changing the `08` at `0x10dbe74` to `0c` would raise Solo to 12. This is
server-side only — the dedicated server runs without EasyAntiCheat — so there is
no ban risk, but a Steam update reverts it and `NumTeams` becomes 12, which is
initially untested. It is now implemented as an in-memory launch patch;
`Trio` still gets 12 players without any patch.

### 12-player Solo — match cap solved, advertised slot count not

Config alone cannot do it: only `Solo`, `Duo` and `Trio` are valid `GameMode`
strings (`LimitedTime1/2`, `PrivateLobby`, `Training`, `CustomMatch` all fall
through to Trio). The Solo maximum is a compile-time constant.

The per-mode maximum is computed by the same
`if Trio then 12 elif Duo then 10 else 8` chain emitted in **five** places with
different register allocations:

```
A 0x10DBE72  41 b9 08 00 00 00   mov r9d, 8
B 0x10DE5C5  bb 08 00 00 00      mov ebx, 8
C 0x10DFBF7  b8 08 00 00 00      mov eax, 8
D 0x10EB529  b8 08 00 00 00      mov eax, 8
E 0x11A8E1A  c7 45 88 08 ...     mov [rbp-0x78], 8
```

`tools/launch_solo12.py` starts the server **suspended**, patches all five in
memory, then resumes — nothing on disk is modified, matching how this is done
elsewhere ("modding the server code without modifying the game files"). It has
to be suspended because the clamp runs ~0.4s after launch and UE4SS does not
inject until ~2.5s.

Result:

```
FactionPlan Seeded! GameMode:2 TeamSize:1 NumTeams:12 MaxPlayers:12
```

Solo, 12 teams of 1, no clamp line at all. **The match cap is genuinely 12.**

**Still unsolved:** the server continues to advertise 8 slots.

```
EOS_SessionModification_AddAttribute() named (NumPublicConnections) with value (8)
```

That number does track the cap in general — `Duo` advertises 10 — but under
patched Solo it stays 8, so a sixth source exists. Ruled out:

- all five constant sites (patched, verified in memory, no change)
- `net.MaxPlayersOverride` in `[SystemSettings]` — accepted, ignored
- `MaxPlayers` under `[/Script/Engine.GameSession]` and
  `[/Script/DeceiveInc.DeceiveIncGameSession]` — no effect
- no imm-8 constant near `UEOSServerSession::CreateSession`
- no sixth 12/10/8 chain and no 8/10/12 lookup table in `.rdata`

It is therefore a **runtime field**, most likely `AGameSession::MaxPlayers`,
which is not reflected (the class exposes only `MaxSpectators`) and so cannot be
reached from UE4SS.

**Open question:** whether the advertised 8 actually rejects a 9th player or is
only the browser's display. Untested — it needs 9 simultaneous clients.

**Also ruled out for the advertised count:** `EOSServerSession` (reached by
following `TripwireDedicatedServerManager.EOSSession`) reflects **zero**
properties, and `DIGameServerSession` has no live instances. The session
settings are a plain `FOnlineSessionSettings` C++ member, so UE4SS cannot see
or write them. The map URL option `?MaxPlayers=12` on the server command line
is accepted and has no effect either.

**Not a client mod.** An unmodified client displays `0/12` for a server running
this, so the 12 is published by the server in its EOS session data. The path
exists; we have not found it.

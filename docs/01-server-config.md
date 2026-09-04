# TripwireServer.ini — complete reference

Location:
```
...\Deceive Inc. Dedicated Server\DeceiveInc\Saved\Config\WindowsServer\TripwireServer.ini
```
Section header: `[/Script/DeceiveInc.TripwireServerSettings]`

Recovered by extracting the config-editor strings from
`DeceiveIncServer-Win64-Shipping.exe`. The server ships a **GUI config editor**
for these — the "Open Config" button on its control panel window.

A stock install writes only 8 of these keys. The rest are accepted but absent.

---

## Server

| Key | Notes |
|---|---|
| `ServerName` | Clamped to a max length; profanity-filtered. |
| `MaxPlayers` | |
| `GameMode` | `Solo` / `Duo` / `Trio`. Unrecognised → falls back to `Trio`. |
| `ServerRegion` | `us-east`, `us-west`, `us-central`, … Blank = auto-detect closest. |
| `Password` | Join password. |
| `AdminPassword` | |
| `bIsPublic` | Show in the server browser. |
| `bIsOfficial` | "Official Tripwire Server" flag. |

## Maps

| Key | Notes |
|---|---|
| `MapRotation` | Short names, **one `MapRotation=` line per map** (see below). |
| `bRandomizeMap` | `True` = random, `False` = round-robin. |

Valid `MapRotation` values — **10** map assets exist, not the 7 that appear in
normal rotation:

```
Hardsell            Hardsell_Day        Silverreef      Diamondspire
FragrantShore       FragrantShore_Night SoundEclipse
Tutorial            TrainingRange       PrivateLobby
```

`Tutorial` is confirmed working — see docs/05. An unrecognised entry logs
`ignoring MapRotation entry '<x>', no playable map matches` and falls back to
the default pool.

### It is repeated keys, NOT comma-separated

This table said "comma-separated" until 2026-09-02. That was **wrong**, and it
cost a scrim: the server took the whole string as one entry and fell back to the
default pool, serving the same map twice.

```
ignoring MapRotation entry 'Diamondspire,SoundEclipse,FragrantShore_Night,...',
  no playable map matches MapData:DA_MapData_Diamondspire,SoundEclipse,...
no MapRotation entry resolves to a playable map, falling back to the default map pool
```

`UTripwireServerSettings.MapRotation` is a `TArray<FString>`, so it needs one
line per element, in the order you want them played:

```ini
MapRotation=Diamondspire
MapRotation=SoundEclipse
MapRotation=FragrantShore_Night
bRandomizeMap=False
```

The earlier confirmed example (`MapRotation=Tutorial`) was a single entry, which
is why the mistake went unnoticed — one element parses fine either way.
`dimod.set_ini_keys` now writes a list value as repeated keys for this reason.

The other way a rotation goes missing is kit-side, not server-side: a profile
that names a key in both `tripwire` and `tripwire_remove` used to write the
value and then delete it, because `apply` processes the removals last. Setting
now wins and `apply` prints `! tripwire_remove ignores <key>`. If a rotation is
being ignored, check the `MapRotation=` lines in the ini before suspecting the
server — absent is a different fault from unparseable.

## Network

| Key | Notes |
|---|---|
| `GamePort` | UDP. |
| `QueryPort` | UDP. Auto-adjusted if it collides with `GamePort`. |
| `bEnableUPnP` | UPnP port mapping. |
| `bCrossplay` | |
| `Platform` | Only applies with crossplay off. `PC` / `Xbox`. |

## Gameplay

| Key | Notes |
|---|---|
| `bSandboxMode` | "Sandbox Mode (Unlock All)". |
| `AutoShutdownEmptyMinutes` | Shut down after N minutes empty. |

## Bots

| Key | Notes |
|---|---|
| `bFillWithBots` | |
| `BotsAmount` | `0` = auto. Clamped per game mode — Solo clamps hard (observed `Range:0,1`). |
| `BotsDifficulty` | `Easy` / `Normal` / `Difficult`. Unrecognised → `Normal`. |

## Heat

Percentage of heat gained for damaging each NPC type, plus decay tuning.
Defaults confirmed from a live server's startup log:

| Key | Default |
|---|---|
| `HeatPercentDamagingCivilian` | 34 |
| `HeatPercentDamagingStaff` | 34 |
| `HeatPercentDamagingGuard` | 17 |
| `HeatPercentDamagingTechnician` | 34 |
| `HeatPercentDamagingVIP` | 100 |
| `ScoldHeatPerSecond` | 1.50 |
| `HeatDelayForSpyHit` | 2.50 |
| `HeatDelayPassiveGain` | 5.00 |
| `HeatDelayAggroPostCover` | 5.00 |
| `HeatDelayToDecay` | 1.00 |
| `HeatDecayRate` | 1.35 |

The server logs the resolved values on every start:

```
TripwireServer Heat Tunables: Bots:8 NPC[Civ:34 Staff:34 Guard:17 Tech:34 VIP:100]
  Scold:1.50 SpyHit:2.50 Passive:5.00 Aggro:5.00 DelayDecay:1.00 Rate:1.35
```

> The `NPC[...]` figures in that line are the **heat percentages above**, not
> NPC population counts. Easy to misread.

---

## Validation

Values are clamped, and every clamp is logged:

```
TripwireServer: Name:%s Value:%d Clamped:%d Range:%d,%d
TripwireServer: Name:%s Requested:%0.2f Clamped:%.02f Range:%0.2f,%0.2f
```

Check `DeceiveInc\Saved\Logs\DeceiveInc.log` after a start to see what actually
took effect.

---

## Not configurable here

Lobby wait time, room item spawns, NPC population, gamblebox rates, suspicion
system. None have an ini key. Lobby wait time is solved via UE4SS — see
docs/05. Command-line `-CommunityBalanceProfile=<path>` also exists.

The mod kit's `DIConfig.ini` is a separate UE4SS configuration surface. Its
general gameplay section can disable cover and suspicion for any stock mode:

```ini
[Gameplay]
DisableSuspicion = 1
DisableCover = 1
```

These are shown under **Gameplay rules** in the profile editor and require the
core `DIConfig` module. They are not native `TripwireServer.ini` keys.

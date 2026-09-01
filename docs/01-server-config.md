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
| `MapRotation` | Short names, comma-separated. See valid values below. |
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

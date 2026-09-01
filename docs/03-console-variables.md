# Console variables

Help text below is the engine's own, extracted from the shipped binary — not
guesswork.

## Killcam

| Variable | Help text |
|---|---|
| `DI.Killcam` | Enables creation of a separate world for instant replay playback |
| `DI.Killcam.AllGameModes` | Enables forced killcam support on all game modes |
| `DI.Killcam.SpyOnly` | If nonzero, Killcam only plays for Spy actors |
| `DI.Killcam.3PView` | If nonzero, Killcam will playback from 3P view |
| `Killcam.RewindTime` | Number of seconds to rewind the killcam for playback |
| `Killcam.StartDelay` | Seconds of delay before playback begins; adds time after death |
| `Killcam.BufferTimeInSeconds` | Frees replay data beyond N seconds; reduces memory use |
| `Killcam.MaxDesiredRecordTimeMS` | Per-frame budget for recording the replay |
| `Killcam.CheckpointSaveMaxMSPerFrame` | Sets CheckpointSaveMaxMSPerFrame on the recording DemoNetDriver |
| `Killcam.GarbageCollectOnExit` | Run GC when leaving deathcam |

## Match reporting

| Variable | Help text |
|---|---|
| `di.UpdateMatchDetailsInterval` | Controls how often match details are refreshed |
| `di.GReportMatchResultsDelay` | Controls how long we wait till sending match results |

## Debug

| Variable | Notes |
|---|---|
| `DI.Debug.BackendEnvironment` | Backend environment selector. **Leave alone** — it points at live services. |

## Usage

Shipping UE builds read console variables from the `[SystemSettings]` section:

```ini
[SystemSettings]
DI.Killcam.AllGameModes=1
DI.Killcam.3PView=1
Killcam.RewindTime=6
Killcam.StartDelay=0.5
```

- **Client:** `%LOCALAPPDATA%\DeceiveInc\Saved\Config\WindowsNoEditor\Engine.ini`
- **Server:** `DeceiveInc\Saved\Config\WindowsServer\Engine.ini`

## Two caveats

**Killcam is client-side.** These were found in the server binary but do nothing
on a dedicated server — they belong in the *client* config.

**Unverified.** Editing `Engine.ini` is a config change, not a binary or pak
edit, so it sits in a different risk class from everything else here. But it
has not been confirmed that this build honours `[SystemSettings]` for these
variables — some titles lock them. Set one, check the effect, then write a
longer list.

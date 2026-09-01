# Ranked MP scoring

Automating a per-player MP summary for a lobby, humans and bots alike.

## The key finding: the game already counts this for us

The in-game **Mission Report** is not a client-side tally. It is

```
ADeceiveIncGameStateBase::GetAllXpEventDisplayInfoForPlayer(ADIPlayerState*)
```

rendered to a widget. Each row is one `DIXPEvent` paired with an
`FXpEventGroupDisplayInfo`, whose `TriggerAmount` is the count — "6
ELIMINATIONS" is `TriggerAmount = 6` on `DIXPEvent::Kill`.

The ranked point system maps onto that enum almost exactly, so scoring does not
require detecting gameplay. It requires reading counters the server already
maintains and multiplying.

## The mapping

| Mission Report row | `DIXPEvent` | MP | Cap |
|---|---|---|---|
| ELIMINATIONS | `Kill` = 2 | +2 each | — |
| VAULT ENTERED | `EnterVault` = 18 | +1 | once |
| FIRST PACKAGE CAPTURE | `FirstObjectivePickup` = 19 | +4 | once |
| PACKAGE | `PickupObjective` = 20 | +1 | once |
| *(vault terminals)* | `VaultComputer` = 22 | +2 each | — |
| *(retinal scanner)* | `ReticalScanner` = 38 | +4 each | — |
| — | `ADIPlayerState.bWon` | +7 | once |

`ReticalScanner` is the studio's own spelling. Intel, `Extract`,
`MatchPlayed`, the `Kill_10`/`Kill_20`/… milestones and every multiplier row
are logged but score nothing.

Win is not an XP event — it is the replicated `bWon` bool on the player state,
corroborated by `EMatchResult` on the game state
(`MissionSucess_ObjectiveExtracted` = 1, `MissionSucess_LastManStanding` = 2).

## Two sources, deliberately both

`DIScore` reads the same numbers two independent ways and prints a `DIVERGE`
line wherever they disagree.

**HOOK** — `ADeceiveIncGameStateBase:HandleXPEvent(DIPlayerState*, DIXPEvent, int32)`
is the single funnel every scoring event passes through. Counting fires
ourselves is uncapped and timestamped.

**POLL** — `ADIPlayerState.XpData.PlayerXpEventInfo` is the server's own running
tally, an array of `{EventType, MaxTrigger, TriggerAmount}`. Free to read at any
time, but `MaxTrigger` (from `FXpEventInfo.MaxEventTrigger` in
`UDIXpEventDataAsset.XpEventsMap`) may clamp it.

If the two agree, the poll is the cheaper long-term answer and no hook is
needed. If the hook counts higher, clamping is real and the hook is the only
correct source.

## What the recon run must establish

1. **`CanGiveXpEvent()`** — a gate on the game state. If it returns false on a
   self-hosted server, `HandleXPEvent` most likely early-outs and *both* tallies
   stay empty. This is the one finding that could invalidate the whole approach.
2. **`MaxTrigger` clamping** — whether poll and hook diverge.
3. **Bots** — Deceive Inc. bots are full bot players with their own controllers
   and `DIPlayerState`s, so they appear in the player array. Whether the XP path
   runs for them is unverified; it may be skipped as an optimisation.

`DIScore` logs all three explicitly.

## Fallback if XP is gated off

Score from the gameplay events instead of the XP layer. Every category has a
non-XP source:

| Rule | Non-XP source |
|---|---|
| Vault terminal | `HandleVaultTerminalDeactivation(DIPlayerState*)`, `OnVaultTerminalDeactivation`, `IncrementVaultDeactivationCount` |
| Briefcase / case held | `ObjectiveCarrier` + `OnObjectiveCarrierChanged(ASpy*)` |
| Extraction | `OnSpyExtractingChange(AExtractionInteractableActor*, ASpy*, bool)` |
| Retinal scanner / terminals | `EInteractableType::RetinalScanner` = 40, `VaultTerminal` = 15, via `InteractionAuthorityComponent` |
| Kills | the damage/death pipeline |
| Win | `bWon` / `EMatchResult` (already non-XP) |

More wiring, but independent of the XP gate and guaranteed to cover bots.
`DIScore` already hooks `HandleVaultTerminalDeactivation` so the recon run
proves out this route at the same time.

## Bot vs human

A name check is not enough. The decisive test is
`APlayerController.NetConnection` — non-nil for a human, nil for a bot —
corroborated by `ASpy.bIsBot` and engine `PlayerState.bIsABot`. `DIScore`
records all three and prints its reasoning per player.

## Usage

```bash
python dimod.py restart scoring
```

Play a match. At `MatchResultsPosted` the report writes itself to
`Win64/DIScore.log`. For a mid-match snapshot:

```bash
python dimod.py score-report
```

```bash
python dimod.py score-log
```

The mod is read-only — no property is written and no side-effecting function is
called, so none of the crash modes in `docs/05-findings.md` apply.

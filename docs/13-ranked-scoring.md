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

## Verified live, 2026-09-01

One match on `LVL_FragrantShore`, 1 human ("Ihelane") + 7 bots, reported at
`GamePhase=3` (VAULT_LOCKED).

**The poll works and is authoritative.** `XpData.PlayerXpEventInfo` came back
fully populated for all 8 player states — Ihelane read `Intel=22`,
`DoorUnlock=18`, `Kill=2`, `Keycard_Purple=1` — and scored 4 MP off two
eliminations. `CanGiveXpEvent()` returned **true**, so the gate that could have
sunk this approach is open on a self-hosted server.

**`MaxTrigger` is a non-issue, and confirms the point spec.** The caps the
server itself carries match the intended semantics exactly:

| Event | `MaxTrigger` | Intended |
|---|---|---|
| `Kill` | 2147483647 | uncapped |
| `VaultComputer` | 2147483647 | uncapped |
| `ReticalScanner` | 2147483647 | uncapped |
| `EnterVault` | 1 | once |
| `FirstObjectivePickup` | 1 | once |
| `PickupObjective` | 1 | once |

Nothing can be clamped away, so a plain read is the entire feature.

**Bots are scored the same as humans.** Bot player states carry populated
`XpData` (a bot read `Intel=1`), so no special handling is needed.

**The hook does not work, and is not needed.** `RegisterHook` on
`HandleXPEvent` reported `registered=true` but never fired once, while the poll
showed `Kill=2` — UE4SS intercepts `ProcessEvent`, and this is a native C++
call that never passes through it. `HandleVaultTerminalDeactivation` likewise
never fired. Both hooks are left in place at zero cost.

This retires the fallback plan as written: the gameplay-event route relies on
the same native functions and would hit the identical wall. It would need the
Stage 3 native invoker, not Lua hooks. Since the XP gate is open, that is moot.

**Two bugs found and fixed:**

- `RegisterHook` on `MatchResultsPosted` refused to register (returned a bare
  function instead of hook ids) — it is a delegate signature, not a callable
  UFunction. Replaced with a `GamePhase == 7` (RESULT_SCREEN) watcher in the
  existing 2s poll loop, which re-arms itself for the next match.
- Bot detection mislabelled all 7 bots as human. `APlayerController.NetConnection`
  is **not** usable as `~= nil`: UE4SS returns a wrapper object for a null
  UObject pointer, so the test was true for everyone. It needs an `IsValid()`
  check. `bIsABot` and `ASpy.bIsBot` agreed with ground truth on all 8 players,
  so they now lead and NetConnection is corroboration only, logged as
  `DISAGREE` if it ever contradicts them.

## Second run: full match, 2026-09-01

`LVL_Silverreef`, played through to `GamePhase=7` with `MatchResult=2`
(`MissionSucess_LastManStanding`). Both fixes verified and the win rule closed.

- **Auto-report fired on its own** at the result screen — the phase watcher
  works and re-arms.
- **Bot detection is correct for all 8.** Ihelane read
  `bIsABot=false, Spy.bIsBot=false, NetConnection=true`; every bot read
  `false/…/NetConnection=false`. With the `IsValid()` check in place
  NetConnection is now accurate too, and all three signals agree — no
  `DISAGREE` lines.
- **The +7 win rule works.** Bot "Hans" had `bWon=true` and scored
  `Kill x3 @2 = 6` + `MatchWin x1 @7 = 7` = **13 MP**. Three other bots scored
  2 MP each on one kill; the human scored 0.

`DIVERGE` reporting is now gated behind `hook_fires > 0`, so a permanently dead
hook stops printing `poll=N hook=0` against every scored event.

**Still unobserved:** `EnterVault`, `FirstObjectivePickup`, `PickupObjective`,
`VaultComputer` and `ReticalScanner` have not yet been seen non-zero. That is
not a defect — this match ended by last-man-standing, so nobody hacked a
terminal, entered the vault or touched the package. Closing it needs a match
where those objectives are actually played. The counters are structurally
present and correctly capped in every report so far.

## Bot vs human

A name check is not enough — the bots use real agent names ("Ace", "Larcin",
"Madame Xiu"), so it is not even a weak signal.

`PlayerState.bIsABot` and `ASpy.bIsBot` lead: they agreed with ground truth on
all 8 players in the live run. `APlayerController.NetConnection` is recorded as
corroboration but **must** be `IsValid()`-checked rather than compared against
nil — UE4SS returns a wrapper for a null UObject pointer, which is what
mislabelled every bot as human on the first run. `DIScore` prints all three per
player and flags `DISAGREE` if NetConnection ever contradicts the flags.

## Usage

```bash
python dimod.py restart scoring
```

Play a match. The report writes itself to `Win64/DIScore.log` when the match
reaches the result screen (`GamePhase == 7`). For a mid-match snapshot:

```bash
python dimod.py score-report
```

```bash
python dimod.py score-log
```

The mod is read-only — no property is written and no side-effecting function is
called, so none of the crash modes in `docs/05-findings.md` apply.

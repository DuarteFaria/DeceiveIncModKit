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

The site's score fields and the game's `DIXPEvent` counters line up one-to-one.
`field` is the exact key the API expects; `mods/DIScore/Scripts/main.lua` holds
this as a single table so the two vocabularies meet in exactly one place.

| Site field | Type | MP | `DIXPEvent` | Cap |
|---|---|---|---|---|
| `Elims` | number | 2 each | `Kill` = 2 | — |
| `Terms` | number | 2 each | `VaultComputer` = 22 | — |
| `Ret Scanner` | checkbox | 4 | `ReticalScanner` = 38 | **once** |
| `Enter vault ` | checkbox | 1 | `EnterVault` = 18 | once |
| `Podium` | checkbox | 4 | `FirstObjectivePickup` = 19 | once |
| `Package Hold` | checkbox | 1 | `PickupObjective` = 20 | once |
| `Win` | checkbox | 7 | `bWon` + `EMatchResult` = 1 | once |
| `LMS` | checkbox | 5 | `bWon` + `EMatchResult` = 2 | once |
| `Timeout` | checkbox | 7 | `bWon` + `EMatchResult` = 4 | once |

`ReticalScanner` is the studio's own spelling. `Enter vault ` keeps its trailing
space because the site's field list has one - kept byte-exact deliberately, so
that if it is a typo it gets fixed on their side rather than silently diverging
here.

Two consequences worth stating plainly, because both differ from the first cut
of this mod:

**`Ret Scanner` is a checkbox, so it scores once.** The game disagrees - its
`MaxTrigger` is `INT_MAX`, meaning repeat scans are possible - so DIScore clamps
to 1 and the log prints `(capped from N)` if it ever fires twice. This is the one
place where the site's rules are stricter than the game's counters.

**The win bonus is three mutually exclusive fields, not a flat +7.** `bWon`
alone is not enough; `EMatchResult` selects which field applies. A last-man-
standing win is `LMS` = **5**, not `Win` = 7. `EMatchResult` = 3
(`MissionFailed_NoAgentsLeft`) has no corresponding field, so a winner under it
is reported and *not* scored rather than silently zeroed.

Unscored events (`Intel`, `Extract`, `MatchPlayed`, `DoorUnlock`, the `Kill_N`
milestones, every multiplier) are still sent under `events` so the site can
display detail the MP table ignores.

### Agents

The site accepts exactly twelve agent names in a fixed spelling. The game gives
two different forms - asset/class names (`Cavaliere`, `MadameXiu`, `YuMi`) and
bot display names (`Cavalière`, `Madame Xiu`) - so DIScore folds both
(lowercase, drop every non-alphanumeric ASCII byte) and looks the result up in a
table keyed by both folded spellings. Accented characters fold to *different*
keys than their unaccented equivalents (`Cavalière` → `cavalire`,
`Cavaliere` → `cavaliere`), so both are listed rather than transliterated.

An unrecognised value resolves to `null` and is logged as `UNRECOGNISED`, so a
wrong agent is never pushed to the API.

### Maps

The site distinguishes Day and Night variants of Hard Sell and Fragrant Shore,
which a `LVL_` level name alone may not. So the map is not derived from the level
name: `UMapData` carries the authoritative `MapDisplayName`, `mapCode` and
`MapFileName`, reachable via `ADeceiveIncGameStateBase::GetCurrentMapData()`.
All three go into the payload; which one matches the site's `mapId` is settled
by the first live report.

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
- **The win rule works.** Bot "Hans" had `bWon=true` and scored
  `Kill x3 @2 = 6` plus the win bonus. Three other bots scored 2 MP each on one
  kill; the human scored 0.

  **Re-scored under the site's real field list, Hans is 11 MP, not 13.** This
  match ended `MissionSucess_LastManStanding`, which is `LMS` = 5, not `Win` = 7.
  The 13 came from an earlier flat +7 for any win, before the three-way win
  split was known. `tools/test_discore_scoring.py` pins this exact case.

`DIVERGE` reporting is now gated behind `hook_fires > 0`, so a permanently dead
hook stops printing `poll=N hook=0` against every scored event.

**Still unobserved:** `EnterVault`, `FirstObjectivePickup`, `PickupObjective`,
`VaultComputer` and `ReticalScanner` have not yet been seen non-zero. That is
not a defect — this match ended by last-man-standing, so nobody hacked a
terminal, entered the vault or touched the package. Closing it needs a match
where those objectives are actually played. The counters are structurally
present and correctly capped in every report so far.

## Website integration

### Why the mod cannot call the API itself

UE4SS Lua has no HTTP client - only `io`. And it should not have one: the
dedicated server is crash-sensitive, and blocking the game thread on a network
round trip during the result screen invites exactly the status-3 exits catalogued
in `docs/05-findings.md`. `io.popen("curl")` would work mechanically and is a bad
idea for the same reason.

So the push is split, which is the right shape anyway:

```
DIScore (Lua)  ->  Win64/DIScore.report.json  ->  pusher (Python)  ->  your API
```

The mod's only job is to write a complete file. Everything that can fail slowly -
DNS, TLS, retries, auth - happens in a process the game server does not depend on.

### The payload

`DIScore.report.json` is written at the same moments as the log: on every manual
`score-report` and once automatically at `GamePhase == 7`. It is rewritten in
place each time, so a mid-match snapshot is superseded by the final one under the
same `match_id`.

```jsonc
{
  "schema": 1,
  "match_id": "20260901T193221Z-3-1788371541",  // stable for the whole match
  "is_final": true,                             // false = provisional snapshot
  "phase": 7,
  "map": "LVL_Silverreef",
  "match_result": 2,
  "match_result_name": "MissionSucess_LastManStanding",
  "can_give_xp": true,
  "reason": "phase=7 (result screen)",
  "reported_at": "2026-09-01T19:32:21Z",
  "mp_table": { "Kill": {"event_id": 2, "mp": 2, "cap": false}, "MatchWin": 7 },
  "players": [
    {
      "name": "Hans",
      "is_bot": true,
      "bandit_id_crc": 123456,
      "unique_id": "...",
      "platform_type": 0,
      "hide_player_name": 0,
      "player_id": 4,
      "won": true,
      "events": { "Kill": 3, "Intel": 5 },
      "breakdown": [
        {"event": "Kill",     "event_id":  2, "raw_count": 3, "counted": 3, "mp_each": 2, "mp": 6},
        {"event": "MatchWin", "event_id": -1, "raw_count": 1, "counted": 1, "mp_each": 7, "mp": 7}
      ],
      "mp": 13
    }
  ]
}
```

`mp_table` is echoed into every payload deliberately: a stored match record stays
interpretable after the MP values are retuned, and the site can re-derive totals
rather than trusting ours.

`events` carries every non-zero counter, including unscored ones like `Intel` and
`DoorUnlock`, so the site can show detail the MP table ignores. `breakdown` covers
only what scored. `raw_count` versus `counted` exposes any cap that was applied -
they differ only if a `MaxTrigger` ever disagrees with our table, which has not
happened yet.

### Identity

The site is Discord-identified: `playerScores` entries take a `discordId` or its
own `playerId`, neither of which the game server knows anything about. The
resolution route chosen is to **fetch the lobby's participants from the API** and
match them to in-game players, so the mapping is never maintained by hand here.

That makes the fields below the *local* half of the join - what DIScore can offer
the matcher - rather than a key the site would accept directly.

`name` is **not** a usable key. It is not unique (one lobby held three "Hans",
another two "Ace" - the bots reuse agent names), not stable across matches, and
`ADIPlayerState.HidePlayerName` lets a player anonymise it.

The payload therefore carries every identity field the player state exposes:

| Field | Type | Verdict |
|---|---|---|
| `bandit_id_crc` | `int32` | Candidate primary key - a CRC of the account's Bandit ID, free to read |
| `unique_id` | string | The true account identity, but it is an `FUniqueNetIdRepl` struct and may not stringify through UE4SS |
| `platform_type` | enum | PC/Xbox/PS - a disambiguator, not a key |
| `player_id` | `int32` | Per-match only. **Never** use as a key; present for debugging |

Which of the first two is usable is an open question that one match answers:
both are now logged on the `identity =` line of every player block, so check
whether `bandit_id_crc` is non-zero and whether it stays the same for the same
account across two matches.

### Delivery requirements for the pusher

- **Idempotent.** `match_id` is minted at `StartPlay` and is stable for the match,
  so a retry cannot double-count. The site should treat `(match_id, player)` as
  the unique key and let `is_final: true` supersede an earlier snapshot.
- **Never lose a match.** Queue on disk and retry rather than fire-and-forget; a
  site outage should not cost a match record.
- **Secrets out of the repo.** API key via environment variable or a gitignored
  config - never in `profiles/*.json`, and never in the game folder.

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

Play a match. The report writes itself to `Win64/DIScore.log` - plus the
machine-readable `Win64/DIScore.report.json` - when the match reaches the result
screen (`GamePhase == 7`). For a mid-match snapshot:

```bash
python dimod.py score-report
```

```bash
python dimod.py score-log
```

The mod is read-only — no property is written and no side-effecting function is
called, so none of the crash modes in `docs/05-findings.md` apply.

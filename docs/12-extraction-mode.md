# 12 — Carrier-extraction game mode (DIExtraction)

A custom mode built entirely from the game's own endgame systems: one
designated player is delivered to the briefcase the moment the vault opens;
everyone else hunts them (the stock `ObjectiveKillCarrier` flow). No client
mod, no native DLL — pure server-side Lua over replicated, server-authoritative
state.

## Design (approach A, "natural grab")

The fragile part of any forced-carrier design is the attach: the static dump
exposes no clean "give spy the briefcase" action. So we never force it. The
mod lets the match start normally, then:

1. **Wait** for `ESpyGamePhase::VAULT_LOCKED` (3) with the designated carrier
   deployed (live pawn). The stock lobby/intro flow spawns everyone first.
2. **Advance once**: `ADeceiveIncMatchGameState:AdvancePhase(true)` — the
   proven genuine timer-expiry branch (route31 evidence). The game runs its own
   `OnVaultUnlockedPhaseStart`, spawning/enabling the briefcase.
3. **Teleport** the carrier's pawn next to the live `BP_Briefcase_C`
   (`K2_TeleportTo`, +150/+60 offset). Retries every second until the
   briefcase exists and the teleport lands.
4. **Hand off.** The player grabs the case through the game's own pickup
   (`ABP_BasePickableActor_C` interaction); the carrier state, kill-carrier
   objectives, extraction call, and win/lose all run stock.

Phase enum (build 24975521): LOADING=0, PREGAME=1, POSING_SPY_INTRO=2,
VAULT_LOCKED=3, VAULT_UNLOCKED=4, EXTRACTION_ARRIVING=5, EXTRACTION_ARRIVED=6,
RESULT_SCREEN=7, GAME_FINISHED=8.

## Usage

```
python dimod.py restart extraction          # profile: DIConfig + DIExtraction, Solo vs 7 bots
python dimod.py trigger-extraction [name]   # arm; optional player-name substring = carrier
python dimod.py extraction-recon            # one-shot state dump into DIExtraction.log
python dimod.py grant-loadout [name|all]    # fill intel/keycards/chips/charges
python dimod.py disguise purple [name]      # NPC disguise clearance, re-applied on deploy
```

### Arming survives restarts (`AutoArm`)

Arming originally lived only in a one-shot marker, and `dimod apply` deletes
every transient marker — so **each restart silently disarmed the mode**, and a
test run then looked like a code failure when nothing happened. DIConfig.ini is
written from the profile and does survive, so the profile declares it:

```ini
[Extraction]
AutoArm = 1
AutoLoadout = 1
Disguise = purple
```

`Carrier = <name substring>` is also accepted. `AutoLoadout` kits the carrier
out automatically when the vault opens — the grant was manual-only at first,
which meant it simply never happened during a normal play session.

The loadout and disguise are applied **before** the teleport is attempted, and
only once per match. Ordering it that way means a teleport that cannot find a
clear spot no longer costs the player their loadout and disguise as well. The `trigger-extraction` and
`disguise` commands still work for ad-hoc changes within a session.

The trigger can be armed before anyone joins — the mod idles until
VAULT_LOCKED with a deployed human. Default carrier is the first human
connection, and the log names whoever it resolved so a test run can confirm the
right player was picked. Log: `DIExtraction.log` in the server Win64 folder.

### Who counts as "human"

Bots in this game are full bot *players*, so a name check is not enough. The
decisive test on a dedicated server is `APlayerController.NetConnection`: every
human arrives over one, no bot has one. `ASpy.bIsBot` and the engine's
`PlayerState.bIsABot` are checked as corroboration.

## Full loadout (`grant-loadout`)

In-match consumables are a replicated, server-authoritative resource pool:
`ASpy.GameplayResourcesComponent` (`UGameplayResourcesComponent`) with
`AddResource(EGameplayResourcesType, Amount, bGiveXpForResource)`,
`GetResourceAmount`, `GetMaxAmount`, replicated via `PlayerResourceAmountMap` /
`OnRep_NewPlayerResourceData`. The mod tops each resource up to the game's OWN
`GetMaxAmount`, so no value can exceed a legitimately full pouch, and passes
`bGiveXpForResource = false` so a debug grant never feeds match progression.

Granted: Ammo, Health, Intel, all four keycards (Green/Blue/Purple/Orange),
every `Charge_*` gadget/ability charge, and the upgrade **chips** —
`PowerupModule_*` (25-30) plus `PowerupModuleLevel_*` (36-40). A max of 0 means
that agent does not use that resource and it is skipped.

**Chips were missing in the first version.** It granted every keycard but
nothing in the powerup row, because `PowerupModule_*` had been dismissed as
internal bookkeeping. They are not: they are the modules looted from NPCs that
level an equipped powerup, and `PowerupModuleLevel_*` records the NPC security
tier a module came from. Intel *was* being granted correctly the whole time
(0 → 10), it is just a small cap — Intel is not the chip row.

The systems connect: `UPowerupManagerComponent::GetPowerupForLevel(ASpy*,
ESecurityLevel)` on the game state means which powerup a spy gets is a function
of the NPC security tier they are wearing. `EPowerupType` is
{Cover, Ammo, Intel, Hacking, Health, Expertise, SocialBattery, Foodie,
Exfiltrator}; which of those you *equip* is a pre-match deck
(`EquippedPowerups`, `SetDeckPowerupToSlot`), so it is account/client side —
the server can feed the modules, not choose the deck.

**Deliberately not granted:** `Mission_Objective` (8) — that is the briefcase
itself (see below). Also skipped are the `PowerupModule*`, `Kill`, `SpyCache`,
and `LimitedEvent*` entries, which are internal bookkeeping counters rather
than player-facing pickups.

A gadget you did not equip still cannot be handed to you mid-match:
`UToolLoadoutComponent` populates its slots at spawn from `TSoftClassPtr`
loadout classes and exposes no "give tool" function. Charges are ammunition for
what you already carry. For opening up the *selection* itself, see sandbox mode
below.

## Sandbox mode (`bSandboxMode`)

`UTripwireServerSettings` ships a real `bSandboxMode` key for TripwireServer.ini
— this is a supported dedicated-server setting, not a mod hack. The `extraction`
profile now sets it.

It feeds `ADeceiveIncMatchGameState.SandboxSettings` (`FSandboxSettings`), which
is on the replicated game state and therefore reaches an untouched client.
Measured A/B on a live server, changing nothing else:

| `bSandboxMode` | `bSandboxUnlocksAll` | `bIsPrivateSandboxGame` | `IsSandboxGame()` |
|---|---|---|---|
| `True`  | **true**  | false | false |
| `False` | **false** | false | false |

So the INI key demonstrably drives `bSandboxUnlocksAll`, the flag whose whole
purpose is opening up agent/loadout choice. `bIsPrivateSandboxGame` stays false
because it means "a sandbox game brokered through the backend private-lobby
flow", which a self-hosted server is not, and `IsSandboxGame()` evidently keys
off that one rather than off `bSandboxUnlocksAll`.

Whether the client's agent-select actually opens up therefore depends on which
of the two it reads, and that can only be settled by looking at the screen.
Ownership itself lives in `UDISessionSubsystem::IsOwnedItemID` /
`IsOwnedItemAccelByteID`, a **GameInstance** subsystem populated from the
account backend — the server never supplies it, so if the client gates on
ownership without consulting the sandbox flag, no server-side setting can move
it. `ECharacterSelectAgentAvailability` is `{Available, Unavailable,
NotPurchased}`.

Note `bSandboxMode` also turns on `bPrivateFillBot`. `bSandboxMode`,
`bFillWithBots` and `bRandomizeMap` are now in `MANAGED_TRIPWIRE_KEYS` so a
profile switch can never leave sandbox silently enabled.

## NPC disguise (`disguise`)

```
python dimod.py disguise purple        # or a tier name, a raw 0-4, or 'off'
python dimod.py disguise vip Ihelane
```

Uses `ASpy::CheatDisguiseGiveSecurityLevelSrv(ESecurityLevel)`. The level is
remembered and re-applied when the carrier deploys, so the extraction phase
begins with the disguise already on rather than needing a second command.

`ESecurityLevel` = {Civilian 0, Staff 1, Guard 2, Technician 3, VIP 4}. The dump
names no colours, but the four keycards run Green < Blue < Purple < Orange and
the four non-Civilian tiers run Staff < Guard < Technician < VIP, so **purple
maps to Technician**. That is an inference from the ordering, not something the
dump states; if the tier looks wrong in game, pass the tier name directly.

### The cheat call never worked; the property write is the real route

`CheatDisguiseGiveSecurityLevelSrv` and its non-Srv twin both resolve
(`type(pawn[fn])` reports `userdata`, so they are exposed) but **every live call
failed**, on three separate runs. UE4SS raised an error whose value was a
*function* rather than a string, which is why the first logs showed only
`function: 0x...`; `describe_error` now calls it to recover the message. This
matches the known UE4SS marshaling boundary that closed Gate A on the spectator
work.

The next attempt — writing `SecurityLevel` on the current disguise — **provably
changed the value server-side** (logged `0 -> 3`, `3 -> 4`, `4 -> 3`) and the
client still showed the old tier. So the client does not read that per-instance
field; it derives the tier from the disguise *actor* — its class, or its NPC
pool via `USecurityLevelData.SecurityLevelForPool`.

That is the useful lesson: a successful server-side write is not the same as a
change the client honours. Confirming the write proved the mechanism was wrong,
not the code.

**Current approach: swap the disguise for an NPC that already is the wanted
tier.** A real Technician has the correct level, pool and mesh, which sidesteps
the question of which field the client consults entirely.
`swap_disguise_to_tier` picks a live `ANPCCharacter` at the target tier that no
other spy is currently wearing (`disguises_in_use`), points the spy's replicated
`DisguiseData.Disguise` at it — nested member write first, then a
read-modify-write of the whole struct, since UE4SS does not always mark a nested
assignment dirty — and fires
`NetMulticast_TriggerChangeDisguiseVisualFeedback` so the client refreshes
through the game's own path. It reports success only if `GetDisguise()` actually
changed.

Editing `SecurityLevel` remains as a last-resort fallback, explicitly logged as
known not to reach the client.

**Confirmed working (2026-09-01).** A live run swapped `BP_Ann_v2_C` (Civilian)
for `BP_EliteAmber_C` (tier 3) and the client showed the new disguise:

```
disguise swap for Ihelane to tier Technician wrote=true
  chosen=BP_EliteAmber_C chosen_tier=3
  before=BP_Ann_v2_C after=BP_EliteAmber_C
```

The nested `pawn.DisguiseData.Disguise = chosen` write was enough — the
whole-struct fallback was not needed. **This also confirms purple = Technician**,
which until now was only an inference from keycard ordering.

`extraction-recon` also reports each human's current disguise actor and its
`SecurityLevel`, so the applied tier can be confirmed from the server.

**Verification bug worth remembering:** the before/after readings first came
back `<unreadable>` on a write that reported `ok=true`, because
`scalar_property` was *used but never defined* in this mod — the name was
carried over from DINativeStage2. It resolved to a nil global, every call
raised, and the surrounding `pcall` swallowed it. A helper that silently
degrades inside a `pcall` will hide its own absence; the write was fine, only
the proof was missing.

With it defined, a live Silverreef sample reads tiers correctly and shows what
each map populates:

| tier | Civilian 0 | Staff 1 | Guard 2 | Technician 3 | VIP 4 |
|---|---|---|---|---|---|
| count | 120 | 60 | 40 | 48 | 2 |

Only two VIPs exist per map, so VIP is a special-case tier rather than a
general disguise class. `extraction-recon` prints this tally plus samples.

The colour→tier mapping is still an inference. `USecurityLevelData`
(`DA_SecurityLevel`) holds a `TMap<ESecurityLevel, FColor> SecurityColors` that
would settle it, but the TMap is not readable through UE4SS reflection — the
instance resolves and the map does not. Since the tier is now visible in game,
confirming it by eye is cheaper than defeating the TMap.

## Gotcha: not every BP_Briefcase_C is the objective

Each spy carries a display-only `BP_Briefcase_C` parented under it, named
`<Spy>_EGameplayResourcesType::Mission_Objective_ItemCache_0`. A live run picked
one of those and "teleported" the carrier onto its own position — a silent
no-op. `is_world_briefcase` now requires an unattached actor whose own object
name starts with `BP_Briefcase_C`, and the teleport additionally refuses any
target within 200uu of the carrier.

That gotcha is also a lead: the briefcase is carried **as**
`EGameplayResourcesType::Mission_Objective` (8) in the spy's item cache, which
means approach B (forced carrier) is probably just
`AddResource(8, 1, false)` on the target spy — the "attach objective to spy"
action the static dump appeared to lack. Untested.

## Incident: teleported below the map (Fragrant Shore)

A live run dropped the player out of the world. Cause: no world briefcase
resolved, so the chain fell back to `BP_VaultZone_C` — **whose actor location
reads `(0, 0, 0)`**. It is a trigger *volume*: the shape lives in its
components, not its transform, so its origin is not a position at all. The
teleport dutifully moved the player to the world origin, under the level.

The earlier "same position as the carrier" guard did not catch it, because
world origin is nowhere near the carrier. Fixes:

- `is_usable_location` rejects anything within 100uu of world origin, plus nil
  and NaN. Volume-style actors are no longer used as targets at all.
- If no usable target exists the mode **waits and teleports nowhere**. Doing
  nothing always beats inventing a destination.
- `probe_objective_classes` runs once when VAULT_UNLOCKED arrives with no
  target, dumping every plausible objective class with positions — the real
  objective actor for Fragrant Shore is still unidentified, and the probe is
  what will name it.
- `python dimod.py rescue [player]` teleports a player back to solid ground,
  anchored on a live NPC (an NPC stands on navmesh by definition).

Standing lesson: **an actor's location is not automatically a place a player
can stand.** Validate a destination before moving anyone to it.

## Where the objective actually is

The probe settled it on Diamondspire. There is **no world briefcase actor**: all
48 `BP_Briefcase_C` instances are per-spy `Mission_Objective_ItemCache_*`
children. The objective's real location is
**`BP_DS_ObjectivePedestal_C`** (1 per map), with `Bp_Objective_Terminal_C`
about 500uu away. `BP_VaultZone_C` had a genuine location here but `(0,0,0)` on
Fragrant Shore — inconsistent, hence its removal as a target.

So the pedestal is the target, and `is_world_briefcase` will essentially never
match. That is fine; it stays as a cheap first choice in case some map does
place one.

**Fragrant Shore then showed the pedestal is not universal either** — it has
`BP_DS_ObjectivePedestal_C: 0`. The one anchor present on every map probed so
far is **`Bp_Objective_Terminal_C`** (note the lowercase `p` in `Bp_`), so the
chain is now briefcase → pedestal → objective terminal.

| Map | briefcase | pedestal | objective terminal |
|---|---|---|---|
| Diamondspire | 0 (48 item caches) | 1 | 1 |
| Fragrant Shore | 0 | 0 | 1 |

Do not trust `BP_VaultZone_C`: it read `(0,0,0)` on Fragrant Shore during one
match and a genuine position in another, which is exactly the inconsistency
that put a player under the map.

## Teleport destinations must be collision-clear

With the pedestal correctly resolved, `K2_TeleportTo` still returned **false**
on every attempt: it sweeps for collision and refuses a destination that
overlaps geometry, and the old fixed `+150 X / +60 Z` offset landed inside the
pedestal. It now tries a spread of candidates — straight above first (drop onto
the objective), then a widening ring at two heights — and takes the first the
engine accepts, logging which one worked.

Retries are capped at `TELEPORT_MAX_ATTEMPTS` (12). The Diamondspire run retried
identically every two seconds indefinitely and buried the log; now it gives up
once, says so, and leaves the vault phase open so the objective is reachable on
foot.

## Verified live (2026-09-01)

- **Full chain fired with a real human player**: armed at PREGAME, idled
  through POSING_SPY_INTRO, `AdvancePhase(true)` at VAULT_LOCKED returned
  `ok=true` and the phase moved to VAULT_UNLOCKED, teleport executed. The
  briefcase it picked was the ItemCache instance (now fixed).
- `BP_Briefcase_C` does not exist at PREGAME; it appears with the vault phases,
  which is why the teleport step polls rather than assumes.
- LVL_SoundEclipse at PREGAME: 0 pedestals, 1 `BP_VaultZone_C` — the fallback
  target exists from match start.
- **Mode confirmed working by the user**: spawned, teleported to the briefcase,
  everything played out as intended.
- **The full mode is confirmed working end to end**: auto-arm on boot → phase
  advance at VAULT_LOCKED → auto loadout → disguise swap to Technician →
  teleport to the objective (offset `(+0,+0,+300)`, the straight-above
  candidate) → handoff to the stock endgame.
- `grant-loadout` confirmed against a deployed spy: keycards, ammo and charges
  all landed. Chips were absent initially and were fixed by adding
  `PowerupModule_*`.
- Still unconfirmed: whether `bSandboxMode` visibly unlocks the client's
  agent-select.

## Safety notes

Follows the spectator-lua-safety rules: no UObject wrappers retained across
ticks (everything reacquired via `FindAllOf` per tick), every engine touch
pcall'd, phase validated before the single `AdvancePhase` call, which is only
issued once per arming and only from VAULT_LOCKED.

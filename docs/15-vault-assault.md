# 15 — 3v3 vault-assault prototype

`vault-assault` is an asymmetric server-only mode built on the stock Trio,
briefcase, phase-clock, and extraction systems. It keeps player bots so one
human can exercise the round flow, while removing the wandering ambient NPCs.

## Start it

```powershell
python dimod.py restart vault-assault
python dimod.py logs 80
```

The profile runs Diamondspire with six slots and one human plus five difficult
player bots. `bFillWithBots=True` asks the stock server to keep empty player
slots filled during testing. `RemoveAmbientNPCs=1` neutralizes only the map's
manager-owned `NPCCharacter` actors (civilians, staff, guards, technicians, and
VIPs); agents and agent bots are separate `Spy` actors and remain in the match.
The NPC actors stay registered internally so the population manager does not
continually respawn them. Their separate `NPCAIActor`, behavior machine, combat
components such as `NPCGuardComponent`, and other additional components are
stopped and verified before the NPC is hidden and made non-colliding. This
matters because hiding only the character leaves guard AI alive and able to
shoot invisible projectiles. If AI shutdown cannot be verified, that NPC stays
visible and the failure is reported instead of creating an invisible attacker.

The shipping dedicated server exits after its result screen and when the final
human leaves an active match. This profile sets `persistent_server: true`, so
the mod-kit launcher supervises those normal exits, starts a fresh server
process, and reinjects UE4SS automatically. There is a brief reconnect window;
`python dimod.py stop` stops both the supervisor and the current server.

## Prototype rules

- Stock `Trio` supplies 3-person teams. Faction `0` is the defending side and
  faction `1` is the attacking side.
- The mod waits until spies are deployed, advances `VAULT_LOCKED` through the
  game's proven timer-expiry path, and begins at `VAULT_UNLOCKED`.
- Defenders are teleported to collision-checked positions around the objective.
  One live vault-door actor is selected pseudo-randomly per match, and all
  attackers are placed together about five metres outside that entrance with
  collision-safe spacing.
- Every human spy gets full legal health, ammo, intel, all four keycards,
  equipped-gadget charges, and upgrade-chip resources. Player bots retain their
  stock loadouts because bulk grants during bot initialization can trigger a
  status-3 shutdown. Friendly fire is explicitly disabled.
- Ambient spawn-data and live manager counts are forced to zero during map load.
  Any NPCs that win that startup race have their AI stopped and are hidden; guard
  hitscan and melee damage is also zeroed so a queued shot cannot come from an
  invisible actor. The five player-bot agents remain in the Trio slots.
- When `DisableSuspicion=1`, every live agent (human or bot) has the underlying
  stamina drain and NPC suspicion checks disabled, stamina kept full, and any
  suspicious state cleared by the 10 Hz gameplay authority loop. The
  replicated undercover flag is also cleared with `DisableCover=1`. Stale intro
  invulnerability and disguise-shield modifiers are removed after deployment so
  bots and humans use the same damage path. All reflected controls are read back
  before the agent is logged as ready.
- Attackers have 120 seconds to pick up the briefcase. Their first valid pickup
  replaces the clock with a single 60-second extraction deadline. That deadline
  continues if the case is dropped and is carried across stock extraction phase
  changes.
- Each defender's stock interaction component blocks the exact interaction type
  reported by the live objective pickup source. On Diamond Spire that source is
  the objective terminal which grants the case. This leaves unrelated doors,
  gadgets, revives, and ordinary pickups available. Replicated resource removal
  remains as a fallback if a game-owned grant bypasses interaction validation.
- Attacker extraction uses the untouched stock extraction and victory flow.
- At objective timeout, defender player states are marked as winners before the
  stock timeout transition.

`DIExtraction.log` records role assignment, each loadout grant, defender staging,
timer writes, valid/invalid pickups, and the timeout winner decision.

## Configuration

The profile writes general rules under `[Gameplay]` and mode-specific rules
under `[Extraction]` in `DIConfig.ini`:

```ini
[Gameplay]
DisableSuspicion = 1
DisableCover = 1

[Extraction]
Mode = vault_assault
AutoArm = 1
AutoLoadout = 1
AssaultTime = 120
SecuredTime = 60
DefenderFaction = 0
AttackerFaction = 1
TeleportDefenders = 1
RemoveAmbientNPCs = 1
```

Omitting both faction ids makes the mod select the two lowest live faction ids.
`TeleportDefenders = 0` leaves both teams at their stock spawn points.
`RemoveAmbientNPCs = 0` restores the stock wandering population.
The two `[Gameplay]` settings are owned by `DIConfig` and apply to every game
mode, not only vault assault. `DisableCover=1` also suppresses DIExtraction's
forced-disguise option so the two systems cannot fight each other. Both are
available under **Gameplay rules** in the profile editor. The cover rule uses
replicated scalar/undercover state and deliberately does not invoke the stock
`AllowCover(false)` transition, which exits the dedicated server at deployment.

## First live-test checklist

1. Confirm the startup log reports Trio, six players, and five bots.
2. Confirm `DIExtraction.log` reports ambient cleanup while still naming
   factions 0/1 and six ready spies.
3. Confirm three defenders are staged at the Diamondspire objective and all six
   players have full resources.
4. Pick up the case as an attacker and verify the HUD clock changes to 60.
5. Drop and recover the case; the clock must not reset.
6. Approach the case as a defender; objective interaction must be unavailable
   and the defender must never become `ObjectiveCarrier`.
7. Complete extraction as an attacker and verify the stock objective victory.
8. Let both the initial and secured clocks expire and verify the defender result.

## Known prototype boundaries

- The game still owns elimination. A full team wipe may trigger its stock
  last-man-standing result before the objective timer, and overriding that rule
  needs a deeper game-mode hook.
- Directly writing `DIPlayerState.bWon` is the best reflected route for timeout
  attribution, but its exact result-screen presentation needs the first live
  timeout test.
- Global native interaction hooks are not used: a live test crashed UE4SS when
  condition traffic increased during spy intro. Defender blocking instead
  reads the live objective pickup source's `InteractableType` (the objective
  terminal on Diamond Spire; a standalone case where one exists), submits that
  exact value to the stock per-player `BlockInteractableTypes` request outside
  callback code, and verifies the pickup source with `IsInteractTypeBlocked` before marking a
  defender ready. This replaced the original unverified hard-coded type 13
  request after a defender produced a stock phase transition without retaining
  the objective.
- Defender positions use the objective anchor plus collision-checked offsets.
  Attacker positions are derived from the selected vault door and the direction
  away from that anchor, rather than hard-coded world coordinates. Diamondspire
  is the initial supported test map; other maps still need a spawn-layout pass
  before joining the rotation.
- Full loadout means all server-owned in-match resources. It cannot equip a
  weapon or gadget the player did not select before deployment.
- The server can keep suspicion inactive and replicate an exposed state, but it
  cannot remove the cover/suspicion widget asset from an unmodified game client.
  Physically deleting that HUD element requires a small client-side mod.

The original `extraction` profile remains unchanged and defaults to
`Mode = carrier_extraction` when no mode is specified.

# Spectator mode: feasibility and implementation plan

This is the authoritative status document for spectator mode. `09`, `10`, and
`11` retain the experiment history; they are not descriptions of a finished
feature.

## Decision

**FINAL VERDICT (2026-09-01): the player-toggled free<->follow hybrid is not
achievable under the constraints (untouched retail EAC client, server-side reach
only). Closed.** Proven three ways: (1) 36 server-side routes all hit the same
client-camera wall; (2) disassembly of the running server shows
`CheatSpectateFreeMoveSrv` / `CheatSpectateFreeMove` / `ServerReturnToPlayer` are
empty `ret` stubs; (3) the same static check on the game CLIENT
`DeceiveInc-Win64-Shipping.exe` shows the free-move cheat is stubbed there too
(while `OnSpectateNextInput`/follow input handlers are real). Free-fly spectating
has no shipped implementation on client or server — it exists only as the
`DebugFreecam` debug tool. The transition glue was compiled out of both shipping
builds, and a client mod (the only place the real code could run) is ruled out.

**Deliverable ceiling (works, stable):** death-spectate `A`/`D` follow of living
agents, plus a one-way server-operated `DebugFreecam` free-flight. Two modes,
chosen at entry, not a seamless in-game toggle. The Stage 3 ProcessEvent invoker
and tracer remain reusable infrastructure for any non-stubbed server function.

Everything below this section is the historical investigation that reached this
verdict; it is no longer an open plan.

---

The game already supplies both halves of the experience:

- normal death spectating has the spectator HUD and lets `A` / `D` select
  living agents;
- a game-created `DebugFreecam` can be made controllable by an untouched Steam
  client and is ignored by bots.

Route 27 can switch one naturally dead player from follow spectating to that
freecam and back without changing the controller out of `Spectating`. On the
return path, the unmodified client restores the spectator overlays and sends
valid previous/next target requests, but its camera remains at the spectator
pawn instead of following the selected agent.

That last client camera/context transition remains a blocker. Native inspection
has also exposed a previously missed dedicated-spectator marker and the shipped
freecam collision switch. Route 28 now preserves the marker for an isolated
client test; it is not yet a validated feature.

## Status update — 2026-09-01 (deploy-then-spectate banked)

The usable result today is the **deploy-then-spectate** flow, and it is stable:
join as a normal player, deploy, die to a bot, and the untouched client enters
the native follow-spectator (HUD + `A` / `D` follow of living agents). The server
stays up. `trigger-stage2` adds a one-way `DebugFreecam` free-roam.

Three findings from this session refine the plan below:

1. **Natural follow-spectating is pawn-less.** `FindAllOf` shows no live
   `DISpectatorPawn` and no `DIFreeSpectator` during it; the controller keeps
   referencing the dead spy body and the follow camera is client-driven.
   Therefore `CheatSpectateFreeMove`/`CheatSpectateFreeMoveSrv` (methods on
   `ADISpectatorPawn`) have no instance to run on from the death path. The native
   free-move is a dedicated-spectator-pawn feature, reachable only where a live
   `DISpectatorPawn` is possessed (the login/handoff path). `trigger-native-freemove`
   was added to test this and correctly reports the pawn-less state.

2. **The login path breaks the client menu wall but the match is unstable.**
   Faction-210 login + the native readiness override get the untouched client
   out of agent-select and into an in-world spectator camera, but the
   zero-combat-player match intermittently hard-crashes in native
   `UDIFactionsManager::AssignFactionToBot`. Writing the replicated
   `bIsAutoSpectating` flag on an already-spectating client also causes a status-3
   exit.

3. **`SetHealth(0)` cannot be used to auto-convert a player.** It kills the spy
   but the human death/killcam flow then status-3 exits; a real bot kill (full
   damage pipeline) is the only clean entry. `force-death` is disabled for this
   reason.

The remaining route to real free↔follow is Gate A's native work, but launched
from the *stable* death-spectator rather than the unstable login match: spawn a
`DISpectatorPawn`, hand it to the already-spectating client, then drive
`CheatSpectateFreeMoveSrv` / `ServerReturnToPlayer` on it. Not yet attempted.

## Product target

One or two designated, unmodified EAC-enabled Steam clients should:

1. join a dedicated server;
2. participate in no combat, objectives, extraction, progression, win, or
   last-player-alive accounting;
3. move through the map with mouse look plus horizontal and vertical flight;
4. switch to follow mode;
5. use `A` / `D` to cycle only through living agents;
6. switch back to free movement;
7. survive disconnects, match completion, and map travel without destabilizing
   the server.

The desired final capacity is the normal competitive-player cap **plus one or
two additional spectator connections**. To avoid coupling camera work to EOS and
login work, the first usable milestone may consume ordinary player slots if
necessary. Server-side designation is accepted for that milestone.

"Free movement" includes noclip through level geometry. The current flying
camera still collides. The shipped settings widget does expose the real
`DebugFreecam` collision-profile switch, but initiating that client-local change
from the server is still unproven.

## What is confirmed

| Capability | Evidence | Status |
|---|---|---|
| Untouched client can follow agents | The natural death flow creates `BP_DISpectatorPawn`, spectator HUD/overlays, and working `A` / `D` input. | Confirmed |
| Server receives target cycling | `A` and `D` call `Server_AskForNextSpectatedActor(false/true)`, followed by `RPC_SpectateActor` with a live spy and its `DIPlayerState`. | Confirmed |
| Untouched client can control freecam | `Server_DEBUGToggleFreecam` creates `DebugFreecam`; direct ownership plus `ClientRestart` provides movement and mouse look. | Confirmed |
| Freecam can pass through geometry | `SetCollisionsEnabled` changes the freecam collision profile through the pawn's native collision path. Server-to-owning-client delivery is not yet established. | Native mechanism found; end-to-end unproven |
| Freecam is non-targetable | Bots did not react to or target the camera in the observed run. | Confirmed for one run |
| Controller can remain in spectator state | Bypassing the built-in freecam release keeps `StateName=Spectating` while Route 27 changes the acknowledged pawn. | Confirmed |
| Return restores target input | A fresh live `GameState.SpectatorClass` restores overlays, `A` / `D` RPCs, and valid server-selected targets. | Confirmed |
| Return restores follow camera | The selected target changes, but the client camera remains fixed at the fresh spectator pawn. | Not solved |
| Player can request the mode switch | Route 27 is controlled by `python dimod.py trigger-stage2`, not by an in-game spectator key. | Not solved |
| Spectator has no gameplay effects | The current route starts only after natural death, but damage, interaction, scoring, and all match accounting have not been exhaustively verified. | Partial |
| Two spectators work simultaneously | The current experiment explicitly refuses unless exactly one human controller exists. | Not tested |
| Spectators join without becoming agents | Login-time Route 29 sets `FactionID=210`, `bIsSpectator`, and `bOnlySpectator`; the client then disables agent choices and Deploy. With no combat player, the lobby never starts and the stock UI has no spectator-ready action. | Role recognition confirmed; lobby transition blocked |
| Spectators are additional to the match cap | Unreal exposes a distinct `GameSession.MaxSpectators`, but the stock client loses `?SpectatorOnly=1` during startup and EOS/login classification is unresolved. | Not solved |
| Stability is production-ready | Individual paths work, but earlier variants caused status-3 exits, an access violation, and heap corruption. No 15-minute plus map-travel gate has passed. | Not ready |

## Current one-client prototype

The safest established sequence is:

1. The player joins normally, selects an agent, and reaches a bot match.
2. The player dies through the normal game flow. This is important: it creates
   the exact spectator HUD, input context, controller state, and pawn expected
   by the client.
3. A single Stage 2 trigger calls the game's debug-freecam creation route,
   identifies the newly created pawn, assigns ownership, and sends
   `ClientRestart`. The client can fly and the controller remains
   `Spectating`.
4. A second trigger bypasses the unsafe built-in toggle-off path, spawns the
   exact live `GameState.SpectatorClass`, restores controller and PlayerState
   links, sends `ClientRestart`, and asks the game for a valid target.
5. Later freecam entries reacquire the old camera by its full-name string and
   current world; no live UE4SS UObject wrapper is intentionally retained
   across callbacks or travel.

This proves that both modes can be entered. It does **not** prove the complete
product because the follow camera does not consume the otherwise-valid target
selection after returning from freecam.

The Stage 2 profile also loads a native DLL, but that DLL is only the Stage 1
exit diagnostic. The spectator transition itself is currently implemented in
UE4SS Lua. Calling this a completed native spectator mod would be inaccurate.

## Why the obvious routes are closed

| Route | Result |
|---|---|
| Set `MaxSpectators` | The value is writable and provides separate engine capacity, but it only caps connections already classified as spectators; it does not classify a normal join. |
| Join with `?SpectatorOnly=1` | Steam/EAC forwards the argument, then Deceive Inc.'s startup flow replaces it with its own startup map. |
| Replace `GameState.SpectatorClass` before agent selection | Bypasses the agent selector and enters an incomplete state. |
| Replace `SpectatorClass` after death | Deceive Inc.'s death path does not respawn through the ordinary Unreal spectator-class path. |
| Call `CheatForceSpectator` on a constructed `SpyCheatsComponent` | Component creation and activation work; both the server wrapper and server RPC are stable no-ops in this shipping context. |
| Call `Controller:Possess` on a spectator/freecam | Reproducibly terminates the server. |
| Overwrite dedicated spectator faction with `255` | Incorrect. Native inspection proves the game uses `FactionID=210`; the earlier route erased its own dedicated marker and therefore could not activate dedicated-spectator UI logic. |
| Call client-local spectator UI functions on the headless server | Terminates the server. |
| Use built-in debug-freecam toggle-off | Changes the server controller from `Spectating` to `Inactive`; pawn recreation cannot repair it. |
| Force `ClientSetViewTarget` after return | The RPC is delivered, but an `Inactive` controller still does not follow; the hook also exposed an unstable UE4SS path. |
| Request a target while `DebugFreecam` is acknowledged | Context-dependent at first, then reproduced as an intentional status-3 exit. Route 27 correctly excludes it. |
| Retain live Lua UObject wrappers across callbacks/travel | Produced heap corruption or teardown access violations. Store stable identifiers and reacquire synchronously instead. |

## Most credible implementation route

### Gate A: recover the game-owned free-spectator transition

Reverse engineer the native implementations and call graph of:

- `ADISpectatorPawn::CheatSpectateFreeMoveSrv()`;
- `ADISpectatorPawn::CheatSpectateFreeMove()`;
- `ADIFreeSpectator::ServerReturnToPlayer()`;
- `ADIFreeSpectator::OriginalBody`;
- the code that applies `DefaultSpectatorKeyboardContext` and
  `DefaultSpectatorGamepadContext`;
- `OnSpectateNextInput`, `OnSpectatePrevInput`, and
  `OnToggleAutoSpectateInput`.

The current reflected `CheatSpectateFreeMove` attempt failed at the UE4SS call
boundary. That does not establish that the native game path is unusable. A
server-native hook can determine whether the function is guarded, stripped, or
simply being invoked with the wrong context.

**Built and tested (2026-09-01) — RESULT: server stubs, route closed.** The
server-native hook was built and worked: `DINativeSpectatorStage3.dll` hooks
`UObject::ProcessEvent` and re-invokes it on the game thread with a `(target,
func)` pair the Lua resolver supplies (`dimod native-invoke <free|follow>`, plus
a `dimod native-trace` tracer). It manufactured a `DISpectatorPawn` and cleanly
dispatched `CheatSpectateFreeMoveSrv` on the game thread — but the call was a
no-op. Disassembling the running server showed why:
`CheatSpectateFreeMoveSrv_Implementation`, the client `CheatSpectateFreeMove`,
and `ServerReturnToPlayer` all resolve to a hollow `ret` stub
(`0x7FF623A0D4B0`). **The spectator free<->follow feature is compiled out of the
dedicated-server binary.** See Route 36 in `11-native-stage2.md`.

This is the **Gate A stop condition** below, now confirmed empirically: the
shipped transition is client-local code with no server implementation, so it
cannot be initiated server-side by any means. Under the no-client-mod / EAC
boundary the requested player-controlled hybrid cannot be delivered via these
functions. The deliverable ceiling is the banked pair (death-spectate A/D follow
+ one-way server `DebugFreecam`). Gate A is closed for the native-function route;
the invoker/tracer remain reusable for any non-stubbed server function.

**Pass condition:** one naturally spectating client switches free -> follow ->
free at least 20 times, follows the target selected by `A` / `D`, and remains
connected for 15 minutes through normal match completion.

**Stop condition:** if the shipped transition requires client-local code that
cannot be initiated by an existing server-to-client RPC, the exact hybrid mode
cannot be delivered under the no-client-mod/EAC boundary. In that case, a
server-operated freecam and ordinary death spectating remain possible as two
separate modes, but not as the requested player-controlled hybrid.

### Gate B: make one spectator a real role

After Gate A passes:

- select the controller by a stable account/product-user ID;
- call `SetupAsDedicatedSpectator()` early and preserve its faction-210 marker;
- convert it without a visible gameplay death if the native transition permits;
- keep it out of faction, alive-player, victory, objective, and progression
  accounting;
- disable collision for the owning client as well as the server. First test the
  existing pawn/collision component APIs; if the client keeps its class-default
  collision, make collision state part of the native replicated transition;
- choose an existing spectator input RPC as the client mode-toggle signal if it
  remains available in both modes; `Server_ToggleAutoSpectate` is a candidate,
  not a confirmed solution;
- clean up spectator and freecam actors on disconnect and map travel;
- keep ordinary player death spectating unchanged.

### Gate C: support a second spectator

Replace all single-controller assumptions with per-controller state. Test two
spectators switching modes independently, disconnecting in either mode, and
traveling together. No live UObject may be stored globally across delayed
callbacks or worlds.

This milestone may still use normal match slots. That is an accepted fallback
for proving two independent spectator roles, not the desired final capacity.

### Gate D: support additional spectator connections

Only after the role itself is stable:

1. separate competitive-player count from total connections;
2. patch login/session approval for one or two reserved spectator connections;
3. publish matching capacity through EOS;
4. ensure reserved spectators consume no faction, spawn, or agent slot;
5. test late joins, reconnects, full servers, and map rotation.

`MaxSpectators` is relevant here, but it does not solve these systems by itself.

## Acceptance checklist

- Untouched, EAC-enabled Steam clients only.
- One and then two configured spectators are selected deterministically.
- Free movement, mouse look, and vertical movement work; collision/noclip policy
  is explicitly decided.
- A mode switch is available without running a command on the server console.
- `A` / `D` visibly follows every living agent and skips eliminated actors.
- Returning to free movement works repeatedly.
- Spectators cannot damage, interact, extract, earn progression, or affect match
  completion.
- No stale pawn, PlayerState, freecam, or input context survives disconnect or
  map travel.
- The server survives 15 minutes, a normal result screen, and at least one map
  rotation.
- Disabling the experimental profile restores ordinary gameplay after restart.

## Product decisions — 2026-08-31

| Question | Decision |
|---|---|
| Capacity | Prefer one or two spectators in addition to the normal player cap. Consuming ordinary slots is an accepted fallback if additional connections prove impractical. |
| Collision | Noclip through walls is required. |
| Initial role selection | Server-side designation is acceptable. A client role-selection UI is desirable later but is not required for the first usable version. |

## Route 29 login result — 2026-09-01

Login-time designation is early enough to preserve the game's faction-210
dedicated-spectator marker without upsetting the active faction manager. The
untouched client recognizes it: every agent and the Deploy action become
disabled. The server remains in `WaitingToStart`, with no pawn and a controller
in spectator state, because a lobby containing only that spectator has no
combat player to start the countdown.

`PlayerReadyForSpawn(true)` is not a workaround. It unconditionally forwards
the cached Ace selection to `ServerSelectAgent`, starts an agent spawn for the
faction-210 PlayerState, and produced a fatal streaming error. Calling the
ordinary player-ready path for a spectator is therefore prohibited.

Native inspection resolved the effective `ReadyToStartMatch` implementation.
It preserves the normal match-state and delayed-start guards, then requires
`NumPlayers + NumBots > 0`. A faction-210 connection increments neither count,
which exactly explains the stalled spectator-only lobby.

Route 30 implements a one-shot dedicated-server hook for that single missing
condition. It remains dormant until Route 29 has successfully assigned faction
210. While both stock counts are zero, it temporarily supplies
`NumPlayers=1` only for the duration of the original readiness call, restores
the real value immediately, and consumes its marker only if every stock guard
passes. It does not call `StartMatch`, `PlayerReadyForSpawn`,
`ServerSelectAgent`, or any spawn function. The DLL validates the exact server
build's instruction signature and refuses to hook after an incompatible game
update.

This now needs an end-to-end login test. Direct forced spawning/start calls
remain prohibited.

## Role-selection UI outlook

A new in-game spectator button is not realistic under the current server-only
boundary. The stock client exposes no such button, and the dedicated server
cannot create or inject client widgets, input assets, or menu behavior. Doing so
normally requires a client mod, which remains outside scope because the client
runs EasyAntiCheat.

The practical first version should select spectators by configured product-user
ID, with an administrator command or external server panel to change the list.
An external pre-match web page could eventually provide role choice without
modifying the game client, but it would still feed the same server-side
allowlist; it would not be an in-game UI.

An in-game selector becomes worth revisiting only if native analysis finds a
shipped, reachable spectator menu/event that the server can legitimately ask
the untouched client to open. Reusing an arbitrary agent selection as a hidden
"spectator" choice would be ambiguous, consume gameplay UI, and should not be
the product design.

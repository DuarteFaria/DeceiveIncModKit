# Native spectator Stage 2

> **Historical experiment log.** The current feasibility verdict, product
> boundary, and next implementation gates are in
> [`08-native-spectator-plan.md`](08-native-spectator-plan.md). Stage 2 is not a
> finished spectator feature.

## Current result: Route 27

Route 27 proves that one naturally dead player can enter a controllable
`DebugFreecam`, return to a fresh `BP_DISpectatorPawn`, and re-enter the same
freecam while the server controller remains in `Spectating`. On return, the
client restores spectator overlays and sends valid `A` / `D` target-selection
RPCs for living agents, but the camera remains fixed at the spectator pawn.

The profile is manual and deliberately supports exactly one human controller.
It does not designate spectators by account, create direct spectator joins,
support two spectators, provide an in-client mode-toggle key, add extra
connection capacity, or pass the production stability gate. The native DLL in
this profile only observes exits; the Stage 2 transition is UE4SS Lua.

Routes below are retained as a lab notebook. Later route findings supersede
earlier conclusions where they conflict.

## Route 1: game-owned spectator transition

The first Stage 2 experiment follows the planned highest-value route without
combining fallbacks:

1. wait for one human to join, select an agent, and enter `InProgress`;
2. explicitly arm `python dimod.py trigger-stage2`;
3. locate `/Script/DeceiveInc.SpyCheatsComponent`;
4. construct it with the human controller as its outer;
5. activate the component;
6. invoke its reflected public `CheatForceSpectator()` wrapper (route 1b; route 1's
   direct `CheatForceSpectatorSrv()` call was a stable no-op);

Route 1b was also a stable no-op. Route 2a replaces raw construction with the
engine-owned `Actor:AddComponentByClass` registration path and an identity
`FTransform`, then calls `CheatForceSpectator()`.

Route 2a registered and activated the component successfully but was also a
stable no-op. Route 3 reconstructs the intended guarded-cheat state explicitly:
spawn the game-owned `DIFreeSpectator`, assign its `OriginalBody`, assign the
component's `SpectatorTest`, and possess the spectator pawn.

The first route-3 attempt safely refused before spawning because it sampled the
original pawn after the guarded wrapper transiently cleared `GetPawn()`. The
corrected route captures the pawn at entry and bypasses the wrapper entirely.
UE4SS 2.4 beta returned nil from the reflected `GetPawn()` UFunction despite a
valid `Pawn` property, so the corrected capture reads `controller.Pawn`
directly.

The next attempt reached `UWorld:SpawnActor` but UE4SS rejected its native
`FVector`/`FRotator` values. Route 3 now unwraps any Unreal parameter wrappers
and normalizes both structs into plain named Lua tables before spawning.

Normalization succeeded: the spectator spawned and both links were valid, but
`Controller:Possess` reproducibly terminated the server before returning.
Route 3b therefore performs a direct reflected ownership handoff and calls
`PlayerController:ClientRestart(NewPawn)`, bypassing the guarded possession
callbacks while retaining Unreal's standard client pawn-restart notification.

Route 3b produced a stable, controllable free camera ignored by bots, but the
client retained player visibility and no spectator HUD because its PlayerState
remained non-spectating. Route 4 calls the reflected game-owned
`DIPlayerState:SetupAsDedicatedSpectator()` before the proven ownership handoff
so faction, spectator flags, HUD context, and replication are initialized as a
coherent state.

Historical correction (2026-08-31): `SetupAsDedicatedSpectator()` was not a
no-op. Native inspection shows that it assigns the reserved `FactionID=210`,
and `GetIsDedicatedSpectator()` checks for exactly 210. Route 5 then overwrote
that marker with `255`, so its missing dedicated HUD was not evidence against
the built-in setup function. Route 28 preserves 210 and uses the live
`GameState.SpectatorClass`; it still requires end-to-end client validation.

Route 5 replicated all four values successfully and remained stable, but the
client still showed no spectator HUD and only highlighted the original agent.
This rules out server-side PlayerState values alone. The next investigation
should target the client spectator initialization/event path, especially
`RPC_SpectateActor`, the local spectator event bus, and HUD/keybind-context
activation. The safe reverse handoff is also still outstanding; do not use the
built-in `P` return path until it is implemented without `Possess()`.

Route 6 adds one isolated client initialization step after the stable route-5
handoff: `DeceiveIncPlayerController:RPC_SpectateActor(OriginalBody,
PlayerState)`. This mirrors the ordinary spectating target event and tests
whether that RPC owns the missing local event-bus/HUD setup.

Route 6 delivered successfully but only reinforced the original-agent highlight;
it created no HUD. Reflection exposes `DISpectatorPawn:ShowUserInterface(bool)`
and shipped spectator HUD assets. Route 7 calls `ShowUserInterface(true)` after
the target RPC and records `GetIsDedicatedSpectator()` to test whether the pawn
itself owns client HUD activation.

Route 7 proved `DIFreeSpectator` is separate from `DISpectatorPawn`: both
`GetIsDedicatedSpectator()` and `ShowUserInterface()` rejected that context.
Route 8 instead spawns `DISpectatorPawn`, retains the original body in Lua,
performs the stable ownership handoff, initializes the original agent as the
spectating target, and calls the follow-spectator's own UI function. Free-move
toggling remains deliberately excluded from this test.

Route 8's follow-spectator handoff briefly showed all bot nameplates and a HUD,
but calling client-local UI code on the headless server terminated it. Route 9
stopped reconstructing the initial transition: it eliminated the sole human
through `HealthComponent:SetHealth(0)` and let the game create and initialize
`DISpectatorPawn`. That established the value of starting from a natural
spectator context, but direct elimination and its match-accounting side effects
were removed from later routes. Current runs require the player to die normally.

The route is inert until the single-use marker is created. It consumes the
marker before constructing or invoking anything, and refuses profiles other
than `native-spectator-stage2`.

The experiment deliberately avoided suppressing exits or modifying the Steam
client. Later routes continued from a naturally created spectator.

## Routes 10-15: establish the natural spectator baseline

- Route 10 tried to reconstruct the follow-spectator client state from a live
  player. It remained incomplete and was removed from the active path.
- Route 11 required natural death, then tried the reflected
  `CheatSpectateFreeMove` route on the live spectator. UE4SS rejected the call
  boundary; this did not prove the underlying native implementation unusable.
- Route 12 used `Server_DEBUGToggleFreecam` as a fallback to make the game
  create the camera pawn.
- Route 13 directly repaired ownership and sent `ClientRestart`. This produced
  the first repeatable, movable freecam while the server controller remained in
  `Spectating`.
- Route 14 used the game's built-in freecam release. It changed the controller
  to `Inactive`, which explained why later pawn and target restoration did not
  restore a follow camera.
- Route 15 restored the observed spectator links and requested a target. The
  server selected a valid actor, but the client lacked the active death-spectator
  camera context needed to follow it.

## Route 16: reflected restore-contract diagnostic

Route 16 preserves Route 15 without adding another lifecycle mutation. On the
first armed trigger it records the reflected parameter lists for
`Server_AskForNextSpectatedActor`, `Server_ToggleAutoSpectate`, and
`RPC_SpectateActor`, then walks the controller, natural spectator, and
PlayerState inheritance chains for spectator/faction/team/target/pawn fields.
This is the prerequisite diagnostic for selecting a live target through the
game-owned server path; it deliberately does not repeat `Possess`, direct
death, `ClientGotoState`, or server-side UI calls.

Route 16 captured all target signatures before its broad property walk reached
the opaque natural spectator and caused an intentional status-3 exit. The
useful result is `RPC_SpectateActor(ActorToSpectate)`,
`Server_AskForNextSpectatedActor(bNext)`, and
`Server_ToggleAutoSpectate()`. The property walk has been removed and must not
be retried.

Route 17 replaces Route 15's incorrectly signed target RPC with one isolated
game-owned selection request. After toggling off freecam it calls
`ClientRestart` on the retained natural spectator, then
`Server_AskForNextSpectatedActor(true)`. Auto-spectate remains excluded so its
effect can be attributed separately if Route 17 restores only part of the UI or
input state.

Route 17 invoked the next-target RPC successfully but did not restore normal
death spectating. Diagnostics showed the missing invariant: freecam release
left controller ownership incoherent and a later cycle showed the human
PlayerState as `bIsSpectator=false`, `bOnlySpectator=true`; repeated attempts
also accumulated stale `DebugFreecam` actors.

Route 18 starts from a clean server and, after the built-in freecam release,
restores the already-observed natural links: spectator `Controller`, controller
`Pawn`, PlayerState `PawnPrivate`, and the `true/true` spectator flags. It forces
a PlayerState net update, calls `ClientRestart` on that natural spectator, then
issues `Server_AskForNextSpectatedActor(true)`. No new lifecycle or UI function
is introduced.

Route 19 adds observation only. It retains Route 18 behavior and records calls
to the Deceive Inc. target/freecam RPCs plus Unreal's client restart, spectator
waiting, view-target, and state RPCs. Each trace includes `Pawn`,
`SpectatorPawn`, `AcknowledgedPawn`, `bPlayerIsWaiting`, `bIsAutoSpectating`, and
the PlayerState reference. This allows a natural death and A/D cycle to be
compared with freecam entry/exit without guessing another restoration call.

The first Route 19 build retained a hook's temporary `self` wrapper inside a
delayed callback. The synchronous trace completed, but dereferencing that
expired UE4SS parameter one millisecond later caused a status-3 exit during
lobby join. Delayed hook-parameter retention has been removed; post-event state
is supplied only by the independent periodic snapshot loop.

Route 19b showed that normal A/D cycling and the failed return both execute the
same valid pair: `Server_AskForNextSpectatedActor` followed by
`RPC_SpectateActor(live bot, bot PlayerState)`. The difference is pawn
acknowledgement. Natural death retains the dead spy as `AcknowledgedPawn`, while
freecam entry changes it to `DebugFreecam`; restarting the opaque retained
spectator never changes it back. The target RPC therefore updates the marker
but has no active death-spectator camera/input context to consume it.

Route 20 replaces the opaque restart target with a fresh instance of the live
GameState's exact `SpectatorClass`. After built-in freecam release it spawns
that class at the freecam transform, assigns controller/PlayerState links
directly, calls `ClientRestart`, waits for acknowledgement, and requests the
next target. It does not call `Possess`, `ClientGotoState`, direct death, or any
server-side UI function. Freecam entry also selects only the newly created
`DebugFreecam`, preventing stale actors from earlier cycles being reused.

Route 20 restored a client-acknowledged `BP_DISpectatorPawn`, mouse-look, agent
overlays, and the spectator A/D input path. The observer showed that every A/D
press still reached `Server_AskForNextSpectatedActor` and produced a valid
`RPC_SpectateActor(live actor, PlayerState)`, but the view remained at the
fresh spectator's transform. This isolates the remaining fault to the final
client camera handoff rather than ownership, acknowledgement, target selection,
or input binding.

Route 21 retains Route 20 and installs one guarded synchronous mirror on
`RPC_SpectateActor`. Only after a successful restored `ClientRestart`, each
game-selected live actor is also sent through Unreal's standard
`ClientSetViewTarget` RPC with a zero-time transition. The mirror is disarmed
before entering freecam, so natural death spectating and freecam creation are
unchanged. It also records the controller's reflected `StateName` at each
transition for diagnosis only; it never writes the state or calls
`ClientGotoState`.

Route 21 did not restore normal death-camera behavior. It successfully emitted
multiple `ClientSetViewTarget` RPCs while A/D selected valid agents, but the
controller remained in `Inactive` and the client still did not follow them. A
subsequent attempt to enter freecam again ended in a null-read access violation
inside UE4SS and status-3 shutdown. The Route 21 hook has therefore been removed
and must not be retried.

The retained read-only `StateName` logging identified the more fundamental
transition: natural death and initial freecam entry both report `Spectating`,
but the built-in freecam release changes the server controller to `Inactive`.
Spawning and restarting a fresh spectator pawn does not change it back. Future
work must identify a safe game-owned server transition from `Inactive` to
`Spectating`; direct `ClientGotoState`, raw state writes, and view-target forcing
are excluded.

Route 22 avoids that destructive transition instead of attempting to repair it.
The first freecam entry still uses `Server_DEBUGToggleFreecam` to let the game
create and initialize `DebugFreecam`. On return, the mod deliberately does not
call the toggle-off path: it retains and detaches that freecam, directly assigns
a fresh instance of the live `SpectatorClass`, calls `ClientRestart`, and asks
the game for the next valid spectating target while `StateName` remains
`Spectating`. Later freecam entries reuse the retained game-created freecam via
the same proven direct ownership and `ClientRestart` handoff. Both directions
refuse unless the controller is still `Spectating`; no state value is written.

Route 22 crashed before its return path was ever invoked. The first freecam
entry completed and remained in `Spectating`, but the process then terminated
abruptly without an Unreal fatal log. Windows Error Reporting recorded heap
corruption (`0xc0000374`) in `ntdll.dll`. The only new first-entry behavior was
retaining the live UE4SS `DebugFreecam` wrapper for reuse, so that strategy has
been removed and must not be retried. Route 20 plus read-only state diagnostics
is restored in deployment; the server is intentionally left stopped.

Route 23 is an isolation build for the next clean run. It performs only the
original Route 13 transition from natural death spectating into a newly created
game-owned `DebugFreecam`, followed by the proven direct ownership assignment
and `ClientRestart`. It retains no freecam UObject between callbacks. Once the
controller pawn is `DebugFreecam`, every further trigger is consumed and
refused without calling any gameplay function. This distinguishes a
nondeterministic Route 13 failure from Route 22's retained-wrapper hypothesis.

Route 23 validated Route 13 successfully. The game-created `DebugFreecam` was
acknowledged, remained controllable, and the dedicated server stayed healthy.
Two later triggers while already in freecam were consumed and refused exactly
as intended. The eventual lobby transition was unrelated to the trigger: the
game log recorded `LAST MAN STANDING, GAME END!`, then the normal result-screen
disconnect and `LeavingMap` travel. The client carried the freecam view into
that transition because no return path existed in this isolation build. This
strengthens the Route 22 diagnosis: retaining a live UE4SS freecam wrapper,
rather than Route 13 itself, introduced the heap-corruption failure.

Route 24 retries the state-preserving design without retaining any live
`DebugFreecam` wrapper between callbacks. The first Route 13 entry stores only
the actor's full-name string. Return uses the controller's current freecam pawn
synchronously, bypasses toggle-off, spawns the live `SpectatorClass`, performs
the established direct ownership plus `ClientRestart` handoff, and requests a
game-owned target while `StateName` remains `Spectating`. A later freecam entry
reacquires the actor with `FindAllOf` by exact name and verifies that it belongs
to the controller's current world. Stale names after map travel are rejected.

Route 24's return produced the spectator agent-name overlays and mouse-look,
but the camera remained fixed and spectator cycling did not respond. Reusing
the named `DebugFreecam` restored the proven movable camera, while its
`ClientRestart` removed the spectator overlay context. Route 25 keeps that
freecam handoff unchanged and, 500 ms after each successful initial or reused
freecam restart, makes one game-owned
`Server_AskForNextSpectatedActor(true)` request. This is an isolated test of
whether the resulting normal `RPC_SpectateActor` update can repopulate agent
names while the acknowledged pawn remains `DebugFreecam`. It adds no UI call,
state mutation, possession, toggle-off, or retained UObject wrapper.

The first Route 25 run established that the delayed target refresh completed
while the client remained connected and the controller stayed on
`DebugFreecam` in `Spectating`. The next trigger happened 19 seconds later and
coincided with the game's own `LAST MAN STANDING, GAME END!` event, so the
observed lobby transition was normal post-match behavior rather than the
refresh call. The server later access-violated during map teardown. Inspection
found that the active natural-spectator branch still assigned the spectator,
view target, and PlayerState UObject wrappers to legacy module globals even
though Route 24 no longer used them. Route 26 makes those diagnostic references
callback-local; only the freecam's full-name string remains persistent across
triggers and map travel.

Route 26 disproved Route 25's target refresh as a safe operation. On a clean
match, the established Route 13 freecam handoff completed at `17:48:55`, but
the dedicated server requested an intentional status-3 exit one second later,
exactly when the delayed `Server_AskForNextSpectatedActor(true)` was due. No
refresh completion marker was written. Its earlier apparent success was
therefore context-dependent and is not safe to repeat while `DebugFreecam` is
the acknowledged pawn. Route 27 removes the refresh from both initial and
reused freecam handoffs, preserves the no-cross-travel UObject cleanup, and
returns freecam entry to the proven direct ownership plus `ClientRestart`
sequence. Server-side spectator target requests cannot be used to create the
agent-name overlay in freecam.

## Route 29: login-time dedicated designation

Route 29 calls `SetupAsDedicatedSpectator()` from `Server_ClientIsReady` when a
one-shot marker designates the next connection. This correctly preserves
`FactionID=210`; the client disables agent selection and Deploy, and the server
keeps the controller spectating without a pawn. With no separate combat player,
the match remains in `WaitingToStart`.

A follow-up call to `PlayerReadyForSpawn(true)` was unsafe. The function called
`ServerSelectAgent` with the cached Ace selection despite faction 210, moved the
match toward `InProgress`, and fatally exited during the resulting agent asset
stream. The experiment was removed.

## Route 30: guarded native readiness count

The live `ADeceiveIncGameModeBase` vtable resolves `ReadyToStartMatch` through
RVA `0x2D999F0` in dedicated-server-preview build 24975521. Its complete stock
predicate is the normal match-state comparison, `bDelayedStart == false`, and
`NumPlayers + NumBots > 0`. Dedicated spectators intentionally do not
contribute to either count.

`DINativeSpectatorStage2.dll` hooks only this implementation. It is inert
unless Route 29 creates `DINativeSpectator.readiness-override` after verifying
`FactionID == 210`. If both stock counts are zero, the hook temporarily changes
`NumPlayers` from zero to one, calls the original predicate, restores the real
count, and deletes the marker only when the original predicate returns true.
This retains the game's own transition path and avoids every agent-selection
and spawn call implicated in the earlier crash.

The hook validates the exact 47-byte function prefix before activation. A game
update therefore produces a logged refusal rather than patching an unknown
address. Profile application also removes all stale one-shot markers so the
override cannot survive a restart.

## Safety boundary

Dedicated-server process only. The Steam client remains untouched and runs
normally with EasyAntiCheat. The Stage 2 DLL changes only the guarded readiness
call and never suppresses errors or process exits.

## Rollback

```powershell
python dimod.py stop
python dimod.py apply death-spectate
python dimod.py launch
```

The Stage 1 and Stage 2 trigger markers are not part of ordinary profiles and
cannot activate after rollback.

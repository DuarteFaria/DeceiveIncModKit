# Native spectator Stage 1 diagnostics

> **Historical diagnostic record.** Stage 1 remains useful for observing exits
> and lifecycle state, but its original gate has been superseded by the Route 27
> findings. See [`08-native-spectator-plan.md`](08-native-spectator-plan.md) for
> the current verdict and next work.

## Boundary

Stage 1 observes the dedicated-server process only. It does not suppress exits,
alter possession, create pawns, change factions, or activate debug freecam. The
Steam client and EasyAntiCheat installation remain out of scope.

The `native-spectator-stage1` profile loads these diagnostics by themselves.
`native-spectator-stage2` also loads the same native observer alongside the Lua
route experiment. All ordinary profiles omit `DINativeSpectatorStage1` from
`native_modules`.

## Artifacts

- `DINativeSpectatorStage1.dll`: hooks selected Windows logging and termination
  APIs to capture module-relative stacks when `RequestExitWithStatus` is emitted
  or process status 3 is requested. Original calls always continue unchanged.
- `DINativeLifecycle`: read-only UE4SS Lua observer for `Possess`, `UnPossess`,
  `StartPlay`, match state, controller/pawn links, player-state links, faction
  fields, and counts of spies/freecams/free spectators.
- `tools/analyze_request_exit.py`: read-only PE/string analysis helper.
  *(Removed in the 2026-09-01 cleanup along with the Stage 1 module it served.
  `tools/analyze_spectator_functions.py` keeps the equivalent
  resolve-and-disassemble recipe.)*

Outputs:

- `native/DINativeSpectator/build/vs2022-x64/bin/DINativeSpectator-stage1.log`
- Dedicated server `Binaries/Win64/DINativeLifecycle.log`
- The ordinary `Saved/Logs/DeceiveInc.log`

## Dependencies

- The Stage 0 MSVC x64, Windows SDK, CMake, and Python dependencies.
- MinHook v1.3.4, vendored at commit
  `c3fcafdc10146beb5919319d0683e44e3c30d537` under `third_party/minhook`.
- Read-only analysis packages: `pefile 2024.8.26`, `capstone 5.0.6`, and
  `iced-x86 1.21.0`.

MinHook is statically linked into the Stage 1 DLL. The original license is
preserved in `third_party/minhook/LICENSE.txt`.

Verified Stage 1 DLL SHA-256:
`5F31A95676232F992A9FA64C07F80FB275080D172570BC35512594B5E2604EFD`.

The isolated `DINativeSpectatorDiagnosticHost` smoke test passed. A synthetic
`RequestExitWithStatus(1, 3)` log line produced a five-frame stack containing
stable module-relative RVAs, and the host retained exit code 0. This validates
observation without testing or suppressing a real server exit.

## Failed instrumentation retained as evidence

Registering UE4SS hooks on `Actor:ReceiveDestroyed` and `Actor:ReceiveEndPlay`
caused a null-call access violation during startup-map teardown. The resulting
error correctly ended in `RequestExitWithStatus(1, 3)`, but it was created by
the observer itself and says nothing about the debug-freecam invariant. Those
hooks were removed. Actor disappearance is observed through safe one-second
polling instead.

## Reproduction workflow

1. Start `native-spectator-stage1` and confirm both diagnostic logs initialize.
2. Join with the untouched client and enter the gameplay map normally.
3. Capture a stable pre-transition lifecycle snapshot.
4. Trigger the existing debug-freecam experiment only as a deliberate manual
   reproduction with `python dimod.py trigger-stage1`, never through an
   automatic profile setting. The command refuses other profiles, requires a
   running dedicated server, and creates a single-use marker. Lua consumes and
   deletes that marker before calling the built-in RPC, so a crash cannot repeat
   it after restart.
5. Allow status 3 to proceed. Do not suppress it.
6. Correlate the native module-relative stack with the Lua lifecycle timeline
   and the game log.
7. Restore `death-spectate` after the evidence is archived.

At this point in the investigation, the gate remained open because a real
debug-freecam status-3 exit had not yet been attributed. Later Stage 2 work
showed that those exits are context-dependent: direct `Possess`, target requests
while `DebugFreecam` is acknowledged, stale UE4SS wrappers, and unsafe teardown
paths can fail differently. There is no single blanket rule that merely having
a `DebugFreecam` causes an exit.

## First controlled reproduction

On Diamond Spire, the one-shot trigger was consumed during `InProgress` with a
normal Ace pawn, faction ID 0, and both spectator flags false. The built-in RPC
returned successfully and automatically changed the controller and
`DIPlayerState.PawnPrivate` link to a live `DebugFreecam`. Immediately after:

- match state remained `InProgress`;
- player array and faction ID remained unchanged;
- `bIsSpectator` and `bOnlySpectator` remained false;
- all eight original spies remained alive;
- one `DebugFreecam` existed and no `DIFreeSpectator` existed;
- no `RequestExitWithStatus` was observed for at least 27 seconds;
- the dedicated server remained alive.

This does not reproduce the historical status-3 exit. It is useful negative
evidence: the mismatched pawn/faction/spectator state alone is not sufficient to
request exit immediately. The historical failure may require another condition
(lobby timing, repeated toggle, explicit possession, map/match transition, or a
later lifecycle check). Do not advance the gate based on this run alone.

## Second controlled reproduction

The route reproduced on Sound Eclipse and remained stable for more than eight
minutes with a full bot match. Client-side observations and server evidence:

- bots did not react to or target the camera;
- the normal gameplay HUD was absent;
- the camera still collided with world geometry and could not pass through it;
- attack input continued to act through the preserved original Ace actor, so
  the current route is not a non-interactive spectator;
- pressing `P` invoked the built-in return path and restored control of Ace;
- the server logged `ASpy::PossessedBy` for the original Ace on return;
- the dedicated server remained alive and no status-3 exit was requested.

This narrows Stage 2 hardening to input isolation, original-body safety and
match accounting, collision policy, and travel/reconnect behavior. The missing
HUD and bot non-targeting behavior already match the desired spectator product.

## Rollback

```powershell
python dimod.py stop
python dimod.py apply death-spectate
python dimod.py launch
```

Stopping the process unloads all native hooks. Never attempt to unload the
Stage 1 DLL in a live server because its detours are process-lifetime scoped.

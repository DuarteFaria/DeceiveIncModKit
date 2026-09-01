# What the runtime route actually opens up

Written after `DIUnstick` was confirmed working in-game. The point of this doc
is to separate **what we have proven**, **what the technique implies**, and
**what stays out of reach** — because those three keep getting conflated.

## The capability, stated plainly

UE4SS gives Lua a handle on the server's live UObject graph. That means three
distinct powers, in increasing order of difficulty:

**Tier 1 — read and write property values.** Any `float`/`int`/`bool`/`enum`
reachable by reflection can be changed at runtime. This is how `LobbyWaitTime`
and `IntroPhaseTime` were done. Cheap, reliable, verifiable by read-back.

**Tier 2 — manipulate live actors.** Move them, hide them, disable collision,
destroy them, spawn more. `DIUnstick` is this tier. It works, and it
replicates: you walked through the doors.

**Tier 3 — call and hook functions.** `RegisterHook` on a `UFunction` lets you
run Lua before/after any reflected call, which is how you would implement real
custom rules rather than just retuned numbers. Untouched so far, and the tier
where the server can be crashed outright (see the hard-won lessons in doc 05).

## The honest limit on all three

**Reflection only sees what the class exposes.** Blueprint logic compiled into
an ubergraph is invisible — that is exactly why the tutorial script is
unrecoverable (doc 05 §4). If the value you want was never a `UPROPERTY`, no
amount of graph-walking will find it.

**Server authority is the boundary.** Anything the client owns is off-limit,
and must stay off-limit: the client runs EasyAntiCheat and must never be
touched. The lobby HUD counting down from 90 while the server runs 15 is that
boundary made visible.

## Why the census exists

`DIProbe` searched six class names we had already guessed. That can confirm a
hunch; it can never surface what we failed to imagine. `DICensus` walks the
entire graph, tallies every studio-authored class, and dumps the scalar
properties of one exemplar each, flagging names that look like knobs.

```bash
python dimod.py restart census
```

Then read `Win64/DICensus_dump.txt`. Run it **with players connected and a
match in progress** — spawn points, NPCs, guards and loadouts do not exist in
an empty server, and those are the interesting half of the graph.

Lines marked `<==` matched the tunable-name heuristic. The heuristic is a
starting point for reading, not a claim of writability: a property being
visible does not mean writing it does anything useful. Everything in doc 05 was
confirmed by read-back plus a measured in-game effect, and nothing should be
called "solved" on weaker evidence than that.

## Known targets waiting on the census

| Target | Status |
|---|---|
| Room item spawns | The original goal. `ObjectSpawningManager` was too thin; the per-room data must live on the spawn-point actors, which only exist mid-match. |
| Suspicion system | `DA_NPCSuspiciousness_Default` holds 5 rank percentages — Tier 1 editable. `CheatToggleSpySuspiciousSystemSrv` is a Tier 3 lead. |
| Player count / solo lobbies | Not yet located. Likely a game-mode or game-state property, so the census should surface it. |
| Gamblebox drop rates | Not yet located, and may be account-service side rather than in the match server. |

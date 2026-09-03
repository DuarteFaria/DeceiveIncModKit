"""Exercise DIScore's scoring + agent canonicalisation under real Lua, using
the code as shipped. Slices the relevant declarations out of the mod so the test
cannot drift from what runs on the server."""
import io, sys
import lupa

src = io.open(sys.argv[1], encoding="utf-8").read()


def slice_between(start_marker, end_marker, include_end=True):
    i = src.index(start_marker)
    j = src.index(end_marker, i)
    return src[i:j + (len(end_marker) if include_end else 0)]


parts = [
    slice_between("local MP = {", "local EVENT_NAMES", include_end=False),
    "local function array(t) t = t or {}; t.__array = true; return t end\n",
    slice_between("local AGENT_CANON = {", "-- The site accepts exactly these"
                  if False else "-- The scrims API wants the AGENT", include_end=False),
    slice_between("local function score_from_counts", "\nlocal function game_state",
                  include_end=False),
    "\n_G.score = score_from_counts\n_G.canon = canon_agent\n",
]

L = lupa.LuaRuntime(unpack_returned_tuples=False)
L.execute("\n".join(parts))
score = L.eval("score")
canon = L.eval("canon")


def run(counts, won, result):
    lua_counts = L.table_from({int(k): int(v) for k, v in counts.items()})
    res = L.eval("function(c,w,r) local l,t,b,s = score(c,w,r) return {total=t, score=s} end")
    out = res(lua_counts, won, result)
    sc = {}
    if out["score"] is not None:
        for k, v in out["score"].items():
            sc[k] = v
    return out["total"], sc


fails = []


def expect(label, got, want):
    if got != want:
        fails.append("%s\n     got  %r\n     want %r" % (label, got, want))
        print("FAIL %s" % label)
    else:
        print("ok   %-46s %r" % (label, got))


# The Silverreef match, re-scored under the site's real field list.
expect("Hans: 3 kills + LMS win",
       run({2: 3}, True, 2), (11, {"Elims": 6, "LMS": 5}))
expect("same player, extraction win",
       run({2: 3}, True, 1), (13, {"Elims": 6, "Win": 7}))
expect("same player, timeout win",
       run({2: 3}, True, 4), (13, {"Elims": 6, "Timeout": 7}))
expect("winner on unmapped result 3 is not scored",
       run({2: 3}, True, 3), (6, {"Elims": 6}))
expect("loser gets no win field",
       run({2: 1}, False, 2), (2, {"Elims": 2}))

# Checkbox caps.
expect("Ret Scanner capped to one",
       run({38: 3}, False, 2), (4, {"Ret Scanner": 4}))
expect("Enter vault capped to one",
       run({18: 2}, False, 2), (1, {"Enter vault ": 1}))
expect("Terms uncapped (number field)",
       run({22: 4}, False, 2), (8, {"Terms": 8}))
expect("Elims uncapped (number field)",
       run({2: 6}, False, 2), (12, {"Elims": 12}))

# A full objective run.
expect("full objective sheet",
       run({2: 2, 18: 1, 19: 1, 20: 1, 22: 3, 38: 1}, True, 1),
       (4 + 1 + 4 + 1 + 6 + 4 + 7,
        {"Elims": 4, "Enter vault ": 1, "Podium": 4, "Package Hold": 1,
         "Terms": 6, "Ret Scanner": 4, "Win": 7}))

expect("nothing at all", run({}, False, 0), (0, {}))
expect("unscored events ignored", run({1: 22, 29: 18}, False, 0), (0, {}))

# Agent canonicalisation: asset spelling and display spelling must agree.
for given, want in [
    ("Ace", "Ace"),
    ("Cavaliere", "Cavalière"),
    ("Cavalière", "Cavalière"),
    ("MadameXiu", "Madame Xiu"),
    ("Madame Xiu", "Madame Xiu"),
    ("YuMi", "Yu-Mi"),
    ("Yu-Mi", "Yu-Mi"),
    ("yu_mi", "Yu-Mi"),
    ("SASORI", "Sasori"),
    ("Chavez", "Chavez"),
    ("Vigil", "Vigil"),
    ("Squire", "Squire"),
    ("Octo", "Octo"),
    ("Red", "Red"),
    ("Hans", "Hans"),
    ("Larcin", "Larcin"),
    ("Ihelane", None),      # a player name, not an agent
    ("", None),
]:
    expect("agent %r" % given, canon(given), want)

# Every one of the site's twelve agents must be reachable.
AGENTS = ["Ace", "Cavalière", "Chavez", "Hans", "Larcin", "Madame Xiu",
          "Octo", "Red", "Sasori", "Squire", "Vigil", "Yu-Mi"]
missing = [a for a in AGENTS if canon(a) != a]
expect("all 12 site agents round-trip", missing, [])

print()
if fails:
    print("FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print("ALL PASS")

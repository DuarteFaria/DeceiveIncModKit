"""build_payload with a real scrim's worth of humans. Offline, no fixtures.

Every live run so far has had exactly ONE human and seven bots, so the
multi-human path - which is what an actual scrim night is - had never executed.
These cases cover it: several humans at once, roster matching across them, the
refusal on an unknown player, and the edges (shared agent, unresolved agent,
empty score).

Run:  python tools/test_scrims_payload.py
"""
import copy, importlib.util, os, sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "sp", os.path.join(KIT, "tools", "scrims_push.py"))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

ROSTER = [
    {"id": "p1", "name": "Ihelane",      "discordId": "100000000000000001"},
    {"id": "p2", "name": "ml_constant",  "discordId": "100000000000000002"},
    {"id": "p3", "name": "Brian",        "discordId": "100000000000000003"},
    {"id": "p4", "name": "Cavalière_fan", "discordId": "100000000000000004"},
]
BY_NAME = {p["name"]: p["discordId"] for p in ROSTER}

BOT = {"name": "Hans", "is_bot": True, "agent": "Hans", "score": {"Elims": 1},
       "mp": 2, "events": {}}

fails = []


def check(label, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + label + (f"   {detail}" if detail else ""))
    if not cond:
        fails.append(label)


def report(humans, n_bots=4):
    """humans: [(name, agent, score)]."""
    players = [{"name": n, "is_bot": False, "agent": a, "score": s,
                "mp": sum(s.values()), "events": {}} for n, a, s in humans]
    players += [copy.deepcopy(BOT) for _ in range(n_bots)]
    return {"players": players, "is_final": True, "match_result": 2,
            "match_result_name": "MissionSucess_LastManStanding",
            "map_short_name": "SoundEclipse"}


# ------------------------------------------------------------ four humans
r = report([("Ihelane", "Red", {"Elims": 2}),
            ("ml_constant", "Chavez", {"Elims": 4, "Terms": 2}),
            ("Brian", "Hans", {"Win": 7, "Elims": 6}),
            ("Cavalière_fan", "Madame Xiu", {"Podium": 4})])
payload, notes = sp.build_payload(r, ROSTER, "MAPID", 1, False)
ps = payload["playerScores"]
check("four humans all appear", len(ps) == 4, f"{len(ps)} entries")
check("every entry carries a discordId", all("discordId" in e for e in ps))
check("discordIds are distinct", len({e["discordId"] for e in ps}) == 4)
check("agents carried through",
      sorted(e["agent"] for e in ps) == ["Chavez", "Hans", "Madame Xiu", "Red"])
check("scores are not cross-contaminated",
      next(e for e in ps if e["agent"] == "Hans")["score"] == {"Win": 7, "Elims": 6})
check("bots are dropped", {e["discordId"] for e in ps} == set(BY_NAME.values()))
check("mapId and mapIndex are passed through",
      (payload["mapId"], payload["mapIndex"]) == ("MAPID", 1))

# --------------------------------- an unknown player refuses the whole push
# A wrong match credits the wrong Discord account, so guessing is never right.
r = report([("Ihelane", "Red", {"Elims": 2}),
            ("SomeoneNotInTheLobby", "Ace", {"Elims": 9})])
try:
    sp.build_payload(r, ROSTER, "MAPID", 1, False)
    check("unknown player refuses the push", False, "built a payload instead")
except SystemExit:
    check("unknown player refuses the push", True)

payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, True)
ps = payload["playerScores"]
check("--skip-unmatched keeps the known player", len(ps) == 1)
check("--skip-unmatched drops only the stranger",
      ps[0]["discordId"] == BY_NAME["Ihelane"])

# ------------------------------------------------------ name normalisation
r = report([("IHELANE", "Red", {"Elims": 1}), ("ml_CONSTANT", "Ace", {"Elims": 1})])
payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, False)
check("matching is case-insensitive", len(payload["playerScores"]) == 2)

# The roster name carries an accent; the folded form must still match.
r = report([("cavaliere_fan", "Cavalière", {"Elims": 1})])
payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, False)
check("accents fold when matching names",
      payload["playerScores"][0]["discordId"] == BY_NAME["Cavalière_fan"])

# ------------------------------------------------------------------- edges
r = report([("Ihelane", "Red", {"Elims": 1}), ("Brian", "Red", {"Elims": 2})])
payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, False)
check("two players may share one agent", len(payload["playerScores"]) == 2)

r = report([("Ihelane", None, {"Elims": 3})])
payload, notes = sp.build_payload(r, ROSTER, "MAPID", 1, False)
e = payload["playerScores"][0]
check("an unresolved agent omits the key rather than sending null",
      "agent" not in e and e["score"] == {"Elims": 3})
check("and says so in the notes",
      any("no resolved agent" in n for n in notes))

r = report([("Ihelane", "Red", {})])
payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, False)
check("a zero score still produces an entry",
      len(payload["playerScores"]) == 1
      and payload["playerScores"][0]["score"] == {})

r = report([], n_bots=8)
payload, _ = sp.build_payload(r, ROSTER, "MAPID", 1, False)
check("an all-bot match produces no player entries",
      payload["playerScores"] == [])

print()
if fails:
    print(f"  {len(fails)} FAILED: " + "; ".join(fails))
    sys.exit(1)
print("  ALL PASS")

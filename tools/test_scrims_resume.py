"""Resume-after-restart behaviour, with both API endpoints stubbed. Offline."""
import importlib.util, sys

spec = importlib.util.spec_from_file_location("sp", "tools/scrims_push.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

ID = {
    "hsn": "jx73nb4yf4w82s60y16sttyhts7gy2ff",  # Hard Sell (Night)  -> Hardsell
    "hsd": "jx7cbar3qvexd11xx2gv660j1n7gypss",  # Hard Sell (Day)    -> Hardsell_Day
    "se":  "jx7cv7drtffmwrs29zhbmw8m597gz116",  # Sound Eclipse
    "fsn": "jx7d9zaq7ywf4jw9dc319e61q17gzqg4",  # Fragrant Shore (Night)
    "fsd": "jx79es6gn8p9xehcbvr1bx19xs7gznn1",  # Fragrant Shore (Day)
    "sr":  "jx775q302hjc9gtmnyw4tpye8x7gyt4h",  # Silver Reef
    "ds":  "jx78v03gsn9t9hjyt49k7v1yk57gz0qa",  # Diamond Spire
}

LINEUP = [("fsd", "Fragrant Shore"), ("sr", "Silver Reef"),
          ("fsn", "Fragrant Shore"), ("hsd", "Hard Sell"), ("ds", "Diamond Spire")]

fails = []


def expect(label, got, want):
    if got != want:
        fails.append(f"{label}\n     got  {got!r}\n     want {want!r}")
        print(f"FAIL {label}")
    else:
        print(f"ok   {label:56} {got!r}")


def stub(scored, lineup=LINEUP):
    """Stub both endpoints: the lineup, and scores for the maps played so far.

    Items in `scored` are either a map key (its first slot in the lineup) or a
    lineup index - the latter is the only way to say "the SECOND Diamond
    Spire", which is exactly the case a mapId cannot express."""
    maps = [{"id": ID[k], "name": n, "mapIndex": i}
            for i, (k, n) in enumerate(lineup)]
    scores = []
    for item in scored:
        idx = (item if isinstance(item, int)
               else next(i for i, (kk, _) in enumerate(lineup) if kk == item))
        # two players per scored map, as the real endpoint returns
        mid = maps[idx]["id"]
        scores += [{"mapId": mid, "mapIndex": idx, "discordId": "1"},
                   {"mapId": mid, "mapIndex": idx, "discordId": "2"}]

    def fake_api(base, path, key, method="GET", body=None):
        if path.endswith("/map-lineup"):
            return 200, {"mapLineup": {"name": "Default Lineup", "maps": maps}}
        if path.endswith("/scores"):
            return 200, {"scores": scores}
        raise AssertionError(path)

    sp.api = fake_api


def written(scored_keys, full=False):
    """The raw MapRotation list, in the order it is written to the INI."""
    return sp.fetch_rotation("https://x", "L", "k", skip_played=not full)[0]


def rot(scored_keys, full=False):
    """The order the server actually PLAYS, which is what the tests care about.

    PickMap returns (counter + 1) % N with the counter starting at 0, so entry
    0 is played last, on the wrap. Deriving the played order here means the
    expectations below read as lineup order and a regression in the shift shows
    up as a wrong ORDER rather than a puzzling off-by-one."""
    w = written(scored_keys, full=full)
    n = len(w)
    return [w[(i + 1) % n] for i in range(n)] if n else []


# --------------------------------------------- rotation resumes correctly
stub([])
expect("fresh scrim: whole lineup", rot([]),
       ["FragrantShore", "Silverreef", "FragrantShore_Night", "Hardsell_Day", "Diamondspire"])

stub(["fsd"])
expect("map 1 scored: resumes at map 2", rot(["fsd"]),
       ["Silverreef", "FragrantShore_Night", "Hardsell_Day", "Diamondspire"])

stub(["fsd", "sr", "fsn"])
expect("three scored: resumes at map 4", rot(["fsd", "sr", "fsn"]),
       ["Hardsell_Day", "Diamondspire"])

# A map played out of order must be skipped without shifting the others.
stub(["sr"])
expect("out-of-order: only the scored one is dropped", rot(["sr"]),
       ["FragrantShore", "FragrantShore_Night", "Hardsell_Day", "Diamondspire"])

stub(["fsd", "sr", "fsn", "hsd", "ds"])
expect("all scored: empty rotation", rot(["fsd", "sr", "fsn", "hsd", "ds"]), [])

stub(["fsd", "sr"])
expect("--full-rotation ignores what was scored", rot(["fsd", "sr"], full=True),
       ["FragrantShore", "Silverreef", "FragrantShore_Night", "Hardsell_Day", "Diamondspire"])


# ------------------------------------------------- index comes from lineup
stub(["fsd", "sr"])
expect("index of map 3 is 2, not a score count",
       sp.resolve_map_index("https://x", "L", "k", ID["fsn"])[0], 2)
expect("index of the LAST lineup map is 4",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[0], 4)
expect("re-pushing an already-scored map keeps its index",
       sp.resolve_map_index("https://x", "L", "k", ID["fsd"])[0], 0)

# The old max+1 heuristic would have said 2 here; the lineup says 3. This is
# the bug the lineup lookup fixes.
stub(["fsd", "sr"])
expect("out-of-order play gets the LINEUP index, not max+1",
       sp.resolve_map_index("https://x", "L", "k", ID["hsd"])[0], 3)

# A map absent from the lineup falls back to counting.
stub(["fsd", "sr"])
expect("map not in the lineup falls back to max+1",
       sp.resolve_map_index("https://x", "L", "k", "jxNOTINLINEUP0000000000000000000")[0], 2)


# ------------------------------------------- the same map twice in a lineup
# A real lineup: 'DS > SE > FSN > SR > HSD > DS'. Skipping by mapId dropped
# BOTH Diamond Spires the moment the first one was played.
DUPES = [("ds", "Diamond Spire"), ("se", "Sound Eclipse"),
         ("fsn", "Fragrant Shore"), ("sr", "Silver Reef"),
         ("hsd", "Hard Sell"), ("ds", "Diamond Spire")]


def drot(scored, full=False):
    stub(scored, lineup=DUPES)
    w = sp.fetch_rotation("https://x", "L", "k", skip_played=not full)[0]
    n = len(w)
    return [w[(i + 1) % n] for i in range(n)] if n else []


expect("dupes, fresh: both Diamond Spires present", drot([]),
       ["Diamondspire", "SoundEclipse", "FragrantShore_Night",
        "Silverreef", "Hardsell_Day", "Diamondspire"])

expect("dupes, slot 0 played: the LAST Diamond Spire survives", drot([0]),
       ["SoundEclipse", "FragrantShore_Night", "Silverreef",
        "Hardsell_Day", "Diamondspire"])

# Five of six slots scored, including both Diamond Spires: only slot 2 left.
expect("dupes, five slots scored: only slot 2 remains",
       drot([0, 1, 3, 4, 5]), ["FragrantShore_Night"])

expect("dupes, first five played: last Diamond Spire is next",
       drot([0, 1, 2, 3, 4]), ["Diamondspire"])

expect("dupes, all six played: empty", drot([0, 1, 2, 3, 4, 5]), [])

# ---------------------------------- and the index a duplicate map is filed at
stub([0], lineup=DUPES)
expect("dupes: second play of Diamond Spire is filed at slot 5, not 0",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[0], 5)

stub([], lineup=DUPES)
expect("dupes: first play of Diamond Spire is filed at slot 0",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[0], 0)

stub([0, 5], lineup=DUPES)
expect("dupes: both slots scored - re-push targets the last",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[0], 5)

stub([0], lineup=DUPES)
expect("dupes: a non-duplicated map is unaffected",
       sp.resolve_map_index("https://x", "L", "k", ID["hsd"])[0], 4)


# ------------------------------------ the lineup is finished (end of a scrim)
# Nothing left to play. The rotation must come back EMPTY rather than wrapping
# to map 1, so a restart cannot replay a finished scrim over its own results.
stub([0, 1, 2, 3, 4, 5], lineup=DUPES)
rotation, notes = sp.fetch_rotation("https://x", "L", "k")
expect("finished lineup: rotation is empty", rotation, [])
expect("finished lineup: the shift does not invent an entry",
       sp.shift_for_server(rotation), [])
expect("finished lineup: says so in the notes",
       any("already scored" in n and "nothing left" in n for n in notes), True)

# And a map played PAST the end resolves onto an occupied slot, which is the
# signal the watcher refuses on.
stub([0, 1, 2, 3, 4, 5], lineup=DUPES)
expect("past the end: slot reports occupied",
       sp.resolve_map_index("https://x", "L", "k", ID["se"])[2], True)

stub([0], lineup=DUPES)
expect("mid-scrim: an unplayed slot is not occupied",
       sp.resolve_map_index("https://x", "L", "k", ID["se"])[2], False)
expect("mid-scrim: the second Diamond Spire is not occupied",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[2], False)

stub([0, 5], lineup=DUPES)
expect("both Diamond Spire slots scored: occupied",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[2], True)

stub([], lineup=DUPES)
expect("fresh lineup: nothing is occupied",
       sp.resolve_map_index("https://x", "L", "k", ID["ds"])[2], False)


# ------------------------------- the server never plays rotation entry 0
# PickMap logs `Index:1` for a six-entry rotation and `Index:0` for a
# one-entry one - (counter + 1) % N, counter starting at 0 each process. So
# the list is written rotated right by one, and a single-entry rotation is
# left alone because 1 % 1 == 0 already.
expect("shift: one entry is untouched", sp.shift_for_server(["A"]), ["A"])
expect("shift: two entries swap", sp.shift_for_server(["A", "B"]), ["B", "A"])
expect("shift: last entry moves to the front",
       sp.shift_for_server(["A", "B", "C", "D"]), ["D", "A", "B", "C"])
expect("shift: empty stays empty", sp.shift_for_server([]), [])
expect("shift: does not mutate its argument",
       (lambda L: (sp.shift_for_server(L), L)[1])(["A", "B", "C"]),
       ["A", "B", "C"])

# The property that matters: whatever the lineup, the played order equals it.
for _lineup in (["A"], ["A", "B"], ["A", "B", "C"],
                ["A", "B", "C", "D", "E", "F"], ["A", "B", "A"]):
    _w = sp.shift_for_server(_lineup)
    _played = [_w[(i + 1) % len(_w)] for i in range(len(_w))]
    expect(f"shift: {len(_lineup)} map(s) play in lineup order", _played, _lineup)

# And the INI order really is shifted, not merely reordered by luck.
stub([])
expect("written INI order is shifted right by one", written([]),
       ["Diamondspire", "FragrantShore", "Silverreef",
        "FragrantShore_Night", "Hardsell_Day"])

print()
if fails:
    print("FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print("ALL PASS")

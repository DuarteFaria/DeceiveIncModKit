"""Offline checks for map/index resolution and the watcher's dedupe, with the
network stubbed out. No request leaves the machine."""
import importlib.util, io, json, os, sys, types

spec = importlib.util.spec_from_file_location("sp", "tools/scrims_push.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

fails = []


def expect(label, got, want):
    if got != want:
        fails.append(f"{label}\n     got  {got!r}\n     want {want!r}")
        print(f"FAIL {label}")
    else:
        print(f"ok   {label:52} {got!r}")


# ---------------------------------------------------------- resolve_map_id
expect("mapCode 'se' resolves",
       sp.resolve_map_id({"map_code": "se"})[0],
       "jx7cv7drtffmwrs29zhbmw8m597gz116")

expect("mapCode is case-insensitive",
       sp.resolve_map_id({"map_code": "SE"})[0],
       "jx7cv7drtffmwrs29zhbmw8m597gz116")

try:
    sp.resolve_map_id({"map_code": "zz", "map": "LVL_Nope"})
    expect("unknown map refuses", "returned", "SystemExit")
except SystemExit as e:
    expect("unknown map refuses loudly", "refused" if "no mapId" in str(e) else str(e), "refused")

try:
    sp.resolve_map_id({})
    expect("empty report refuses", "returned", "SystemExit")
except SystemExit:
    expect("empty report refuses", "refused", "refused")


# ------------------------------------------------------- resolve_map_index
def stub_scores(rows):
    def fake_api(base, path, key, method="GET", body=None):
        return 200, {"scores": rows}
    sp.api = fake_api


stub_scores([])
expect("empty lobby -> index 0",
       sp.resolve_map_index("https://x", "L", "k", "MAP_A")[0], 0)

stub_scores([{"mapId": "MAP_A", "mapIndex": 0, "discordId": "1"},
             {"mapId": "MAP_A", "mapIndex": 0, "discordId": "2"}])
expect("new map after one recorded -> index 1",
       sp.resolve_map_index("https://x", "L", "k", "MAP_B")[0], 1)

expect("SAME map re-pushed reuses its index",
       sp.resolve_map_index("https://x", "L", "k", "MAP_A")[0], 0)

stub_scores([{"mapId": "MAP_A", "mapIndex": 0}, {"mapId": "MAP_B", "mapIndex": 1},
             {"mapId": "MAP_C", "mapIndex": 2}])
expect("three recorded -> next index 3",
       sp.resolve_map_index("https://x", "L", "k", "MAP_D")[0], 3)

expect("middle map re-pushed reuses index 1",
       sp.resolve_map_index("https://x", "L", "k", "MAP_B")[0], 1)

# Gaps must not collapse: max+1, never count.
stub_scores([{"mapId": "MAP_A", "mapIndex": 0}, {"mapId": "MAP_C", "mapIndex": 5}])
expect("gappy indices -> max+1, not count",
       sp.resolve_map_index("https://x", "L", "k", "MAP_Z")[0], 6)

# Malformed rows must not crash or skew the result.
stub_scores([{"mapId": None, "mapIndex": None}, {"mapId": "MAP_A", "mapIndex": 0},
             {"mapIndex": "not-an-int"}, {}])
expect("malformed rows ignored",
       sp.resolve_map_index("https://x", "L", "k", "MAP_NEW")[0], 1)


# ------------------------------------------------------------ push dedupe
tmp = os.environ.get("TEMP", ".")
sp.PUSHED = os.path.join(tmp, "test-scrims-pushed.json")
if os.path.exists(sp.PUSHED):
    os.remove(sp.PUSHED)

expect("pushed set starts empty", sp.load_pushed(), set())
sp.save_pushed({"m1", "m2"})
expect("pushed set round-trips", sp.load_pushed(), {"m1", "m2"})
sp.save_pushed({f"m{i}" for i in range(600)})
expect("pushed set is bounded at 500", len(sp.load_pushed()), 500)
os.remove(sp.PUSHED)

print()
if fails:
    print("FAILURES:\n" + "\n".join(fails))
    sys.exit(1)
print("ALL PASS")

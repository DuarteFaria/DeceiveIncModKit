#!/usr/bin/env python3
"""
scrims_push - send a DIScore match report to the scrims site.

    GET  /api/lobbies/<lobby>/players   -> roster (id, name, discordId)
    PUT  /api/lobbies/<lobby>/scores    <- mapId, mapIndex, playerScores[]

The mod cannot make this call itself: UE4SS Lua has no HTTP client, and the
dedicated server is too crash-sensitive to block the game thread on a network
round trip at the result screen. So DIScore writes Win64/DIScore.report.json and
this runs separately, where a slow DNS lookup or a 500 costs nothing.

Stdlib only - no requests, no dependencies to install on the server box.

    python tools/scrims_push.py --print-rotation                   # read-only check
    python tools/scrims_push.py --print-roster                    # read-only check
    python tools/scrims_push.py --lobby <id> --map-id <id> --map-index 0 --dry-run
    python tools/scrims_push.py --lobby <id> --map-id <id> --map-index 0
    python tools/scrims_push.py --watch            # hands-off: push each match
    python tools/scrims_push.py --flush            # retry whatever queued

Environment (see .env.example; .env in the kit root is loaded automatically):
    SCRIMS_API_KEY    bearer token (required; never logged)
    SCRIMS_BASE_URL   e.g. https://<deployment>.convex.site
    SCRIMS_LOBBY_ID   default for --lobby
"""
import argparse, json, os, sys, time, unicodedata, urllib.error, urllib.request

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The kit root holds dipaths.py, and this script is run as tools/scrims_push.py
# rather than as part of a package.
if KIT not in sys.path:
    sys.path.insert(0, KIT)
import dipaths

# Distinct from 1 (failure): the lineup is finished, which is a normal end
# state, not an error. Callers should leave the rotation alone, not warn.
EXIT_LINEUP_DONE = 3


def load_dotenv(path=None):
    """Minimal KEY=VALUE reader - a dotenv dependency is not worth adding for
    three variables. A real environment variable always wins, so a one-off
    override on the command line works without editing the file."""
    path = path or os.path.join(KIT, ".env")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if value[:1] == value[-1:] and value[:1] in ("'", '"'):
            value = value[1:-1]
        os.environ.setdefault(key, value)


# Before anything reads os.environ, so argparse defaults see .env values.
load_dotenv()

# Resolved by the kit's shared resolver, so the pusher and dimod can never
# disagree about where the server is. KIT is on sys.path above for this.
SERVER = dipaths.SERVER
WIN64 = dipaths.WIN64
REPORT = os.path.join(WIN64, "DIScore.report.json")

# Failed pushes land here rather than being lost. A site outage should never
# cost a match record.
QUEUE = os.path.join(KIT, ".scrims-queue")

# Optional, gitignored: {"in-game name": "roster name or discord id"} for players
# whose DI account name differs from the name the site has registered.
ALIASES = os.path.join(KIT, "scrims-aliases.json")

TIMEOUT = 20

C = {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "b": "\033[1m", "d": "\033[2m", "x": "\033[0m"}
def c(k, s): return f"{C[k]}{s}{C['x']}"


# ---------------------------------------------------------------- matching

def fold(name):
    """Case/whitespace/accent-insensitive key for comparing names.

    'Cavalière' and 'Cavaliere' must land on the same key, and so must
    'Madame Xiu' and 'madamexiu' - the game and the site disagree on all three
    dimensions depending on which field a name came from.
    """
    if name is None:
        return ""
    s = unicodedata.normalize("NFKD", str(name))
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    return "".join(ch for ch in s.lower() if ch.isalnum())


def load_aliases():
    try:
        with open(ALIASES, encoding="utf-8") as f:
            return {fold(k): v for k, v in json.load(f).items()}
    except FileNotFoundError:
        return {}
    except Exception as e:
        print(c("r", f"  ! {os.path.basename(ALIASES)}: {e}"))
        return {}


def match_players(players, roster):
    """-> (matched, unmatched). Deliberately conservative: exact name, then a
    folded compare, then an explicit alias. Anything else is reported as
    unmatched rather than guessed, because a wrong match credits the wrong
    Discord account and that is worse than pushing nothing."""
    by_exact = {}
    by_fold = {}
    by_id = {}
    for entry in roster:
        name = entry.get("name")
        if name is not None:
            by_exact.setdefault(name, entry)
            by_fold.setdefault(fold(name), entry)
        for key in ("discordId", "id"):
            if entry.get(key):
                by_id.setdefault(str(entry[key]), entry)

    aliases = load_aliases()
    matched, unmatched = [], []

    for p in players:
        name = p.get("name")
        entry = by_exact.get(name)
        how = "exact name"

        if entry is None:
            entry = by_fold.get(fold(name))
            how = "folded name"

        if entry is None:
            target = aliases.get(fold(name))
            if target is not None:
                entry = (by_exact.get(target) or by_fold.get(fold(target))
                         or by_id.get(str(target)))
                how = f"alias -> {target}"

        if entry is None:
            unmatched.append(p)
        else:
            matched.append((p, entry, how))

    return matched, unmatched


# -------------------------------------------------------------- map + index

MAPS = os.path.join(KIT, "scrims-maps.json")


def resolve_map_id(report):
    """-> (mapId, how).

    map_file_name is tried FIRST, deliberately. The site distinguishes Day and
    Night variants of Hard Sell and Fragrant Shore, but mapCode appears not to:
    LVL_FragrantShore (confirmed Day) reports mapCode 'fs', which the Night
    variant very likely shares. Preferring the code would silently file Night
    matches as Day - a wrong-but-plausible result, which is worse than an
    error. MapDisplayName is not an option at all; it reads nil on a dedicated
    server."""
    try:
        with open(MAPS, encoding="utf-8") as f:
            table = (json.load(f) or {}).get("maps", {})
    except FileNotFoundError:
        raise SystemExit(c("r", f"  {os.path.basename(MAPS)} not found - cannot resolve the map"))
    except Exception as e:
        raise SystemExit(c("r", f"  {os.path.basename(MAPS)}: {e}"))

    for field in ("map_short_name", "map_file_name", "map_code", "map"):
        value = report.get(field)
        if not value:
            continue
        entry = table.get(value) or table.get(str(value).lower())
        if entry and entry.get("mapId"):
            return entry["mapId"], f"{field}={value!r} -> {entry.get('name', '?')}"

    seen = {f: report.get(f)
            for f in ("map_short_name", "map_file_name", "map_code", "map")}
    raise SystemExit(
        c("r", f"\n  refused: no mapId for this map. Report says {seen}\n") +
        c("d", f"  Add it to {os.path.basename(MAPS)} under \"maps\", keyed by mapCode.\n"
               "  Win64/DIScore.catalogue.txt lists the mapCode of every map.\n"))


# The 10 short names TripwireServer.ini MapRotation accepts
# (docs/01-server-config.md). Used to pick the rotation-valid key when several
# keys in scrims-maps.json share one mapId - the table also holds file-name
# fallbacks, which the server would reject.
ROTATION_NAMES = {
    "Hardsell", "Hardsell_Day", "Silverreef", "Diamondspire",
    "FragrantShore", "FragrantShore_Night", "SoundEclipse",
    "Tutorial", "TrainingRange", "PrivateLobby",
}


def short_names_by_map_id():
    """-> {mapId: rotation short name}. Only keys the server would actually
    accept; the file-name fallbacks in the table are skipped."""
    try:
        with open(MAPS, encoding="utf-8") as f:
            table = (json.load(f) or {}).get("maps", {})
    except Exception as e:
        raise SystemExit(c("r", f"  {os.path.basename(MAPS)}: {e}"))
    out = {}
    for short, entry in table.items():
        if short in ROTATION_NAMES and entry.get("mapId"):
            out[entry["mapId"]] = short
    return out


def fetch_lineup(base, lobby, key):
    """-> (name, [{id, name, mapIndex}] sorted by mapIndex).

    The lineup is the single source of truth for both which maps are played and
    what index each one is. Everything downstream keys off mapId, never off the
    name: the lineup reports "Fragrant Shore" with no Day/Night suffix, so two
    entries can share a name while being different maps."""
    status, data = api(base, f"/api/lobbies/{lobby}/map-lineup", key)
    lineup = (data or {}).get("mapLineup") or {}
    maps = sorted(lineup.get("maps") or [], key=lambda m: m.get("mapIndex", 0))
    return lineup.get("name"), maps, status


def scored_positions(base, lobby, key):
    """-> set of lineup slots (mapIndexes) the lobby already holds scores for.

    A lineup POSITION is identified by mapIndex, never by mapId: a lineup may
    legitimately play the same map twice ("DS > SE > FSN > SR > HSD > DS"), and
    a set of mapIds cannot tell position 0 from position 5. Keying the skip on
    mapId dropped both Diamond Spires as soon as the first one was played.

    Rows without a usable mapIndex are ignored rather than guessed at: that
    errs toward replaying a map, which is visible and fixable, instead of
    silently skipping one."""
    status, data = api(base, f"/api/lobbies/{lobby}/scores", key)
    rows = (data or {}).get("scores", [])
    return {r["mapIndex"] for r in rows if isinstance(r.get("mapIndex"), int)}


def shift_for_server(rotation):
    """Rotate right by one, because the server never plays entry 0.

    Observed on every round-robin launch: the server boots onto
    LVL_StartupServer (a stub, not a rotation map), then HealthCheckLoadMap
    calls PickMap, which logs `Index:1` for a six-entry rotation and `Index:0`
    for a one-entry rotation. That is `(counter + 1) % N` with the counter
    starting at 0 - so the FIRST map actually played is rotation[1], and
    rotation[0] is skipped until the list wraps.

    Confirmed live 2026-09-02: with the shift in place a six-map lineup served
    its maps in lineup order. The rule is inferred from the log rather than read
    out of the binary, but it has held for every launch since.

    A one-entry rotation hid this for a long time: 1 % 1 == 0, so it served the
    right map and looked like proof that rotations start at index 0.

    Rotating right by one puts lineup[0] at rotation[1], and the wrap lands the
    displaced last map at index 0 exactly when its turn comes:

        lineup   L0 L1 L2 L3 L4 L5
        written  L5 L0 L1 L2 L3 L4
        played       L0 L1 L2 L3 L4  then 6%6=0 -> L5

    Correct for every length, including 1, where it is a no-op.

    The counter resets each process, so this composes with resuming: after a
    restart the first playable map is again rotation[1], which is the first
    unscored map."""
    if len(rotation) < 2:
        return list(rotation)
    return [rotation[-1]] + list(rotation[:-1])


def fetch_rotation(base, lobby, key, skip_played=True):
    """-> (list of short names, notes).

    With skip_played, maps the lobby already has scores for are dropped, so
    rotation position 0 is the NEXT map to play. That is what makes a restart
    mid-scrim resume correctly instead of replaying the lineup from the top -
    the server always starts a rotation at index 0, so the rotation itself has
    to start at the right map."""
    lineup_name, maps, status = fetch_lineup(base, lobby, key)
    notes = [f"lineup {lineup_name!r} ({status}) - {len(maps)} map(s)"]

    played = scored_positions(base, lobby, key) if skip_played else set()
    if played:
        notes.append(f"{len(played)} lineup slot(s) already scored - skipping them")

    by_id = short_names_by_map_id()
    rotation, unknown = [], []
    for m in maps:
        mid, name, idx = m.get("id"), m.get("name"), m.get("mapIndex")
        short = by_id.get(mid)
        if short is None:
            unknown.append((idx, name, mid))
            notes.append(f"  [{idx}] {name!r} -> UNKNOWN mapId {mid}")
        elif idx in played:
            notes.append(f"  [{idx}] {name!r} -> {short}   (already scored, skipped)")
        else:
            rotation.append(short)
            notes.append(f"  [{idx}] {name!r} -> {short}")

    if unknown:
        listing = "".join(f"\n    index {i}: {n!r}  id={m}" for i, n, m in unknown)
        raise SystemExit(
            "\n".join(notes) + "\n" +
            c("r", f"\n  refused: {len(unknown)} lineup map(s) have no entry in "
                   f"{os.path.basename(MAPS)}:{listing}\n") +
            c("d", "  A partial rotation would silently shift every later map, so\n"
                   "  nothing was written. Add the mapId(s) above to the table.\n"
                   "  NOTE: the ids there were transcribed from a screenshot, so an\n"
                   "  'unknown' id may just be a typo in the table.\n"))

    if not rotation and maps:
        notes.append("every lineup map is already scored - nothing left to play")

    shifted = shift_for_server(rotation)
    if len(shifted) > 1:
        notes.append(f"shifted right by one so the server's first pick "
                     f"(index 1) is {rotation[0]!r}; {shifted[0]!r} sits at "
                     f"index 0 and plays last, on the wrap")

    return shifted, notes


def resolve_map_index(base, lobby, key, map_id):
    """-> (mapIndex, how, occupied).

    `occupied` means the chosen slot ALREADY holds scores, so writing to it
    replaces a result rather than adding one. Callers decide what to do; the
    watcher refuses, because overwriting a finished scrim is data loss on the
    site.

    The lineup decides. Asking it "what index is this map?" is correct however
    the maps are played - out of order, after a restart, or replayed - whereas
    counting existing scores only works if every match happens in lineup order
    starting from zero. Counting is kept as a fallback for a map that is not in
    the lineup at all."""
    try:
        _, maps, _ = fetch_lineup(base, lobby, key)
        slots = [m for m in maps
                 if m.get("id") == map_id and isinstance(m.get("mapIndex"), int)]
        if slots:
            played = scored_positions(base, lobby, key)
            # The match being pushed has not been scored yet, so the first slot
            # for this map that is still empty is the one just played. This is
            # what makes a lineup containing the same map twice work.
            for m in slots:
                if m["mapIndex"] not in played:
                    how = f"lineup slot {m['mapIndex']} for {m.get('name')!r}"
                    if len(slots) > 1:
                        how += f" (first unscored of {len(slots)})"
                    return m["mapIndex"], how, False
            # Every slot for this map is scored: a re-push. With one slot that
            # is unambiguous; with several we cannot know which match is being
            # corrected, so take the last and say so.
            last = slots[-1]["mapIndex"]
            how = f"lineup slot {last} - already scored"
            if len(slots) > 1:
                how = (f"all {len(slots)} slots for this map are already "
                       f"scored - the last is {last}")
            return last, how, True
    except Exception as e:
        # Never fatal: fall through to the score-count heuristic below.
        print(c("y", f"  lineup lookup failed ({type(e).__name__}), "
                     f"falling back to counting scores"))

    status, data = api(base, f"/api/lobbies/{lobby}/scores", key)
    scores = (data or {}).get("scores", [])

    existing = {}
    for row in scores:
        mid, idx = row.get("mapId"), row.get("mapIndex")
        if mid is not None and isinstance(idx, int):
            existing.setdefault(mid, idx)

    if map_id in existing:
        return existing[map_id], f"map already at index {existing[map_id]}", True

    indices = [i for i in (r.get("mapIndex") for r in scores) if isinstance(i, int)]
    nxt = (max(indices) + 1) if indices else 0
    return (nxt, f"{len(set(indices))} map(s) already recorded - next free "
                 f"index {nxt}", False)


# ------------------------------------------------------------------- http

def api(base, path, key, method="GET", body=None):
    url = base.rstrip("/") + path
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read().decode("utf-8", "replace")
        return r.status, (json.loads(raw) if raw.strip() else None)


def redact(text, key):
    """Never let the bearer token reach a log or the terminal."""
    return text.replace(key, "<SCRIMS_API_KEY>") if key else text


# ------------------------------------------------------------------ queue

def enqueue(item):
    os.makedirs(QUEUE, exist_ok=True)
    path = os.path.join(QUEUE, f"{int(time.time() * 1000)}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(item, f, indent=2)
        # Trailing newline: a queued payload is read back by --flush and
        # may well be looked at by hand first.
        f.write("\n")
    return path


def queued():
    if not os.path.isdir(QUEUE):
        return []
    return [os.path.join(QUEUE, f) for f in sorted(os.listdir(QUEUE))
            if f.endswith(".json")]


# ------------------------------------------------------------------ build

def build_payload(report, roster, map_id, map_index, skip_unmatched):
    """-> (payload, notes). Bots are dropped: they have no Discord identity and
    the API has no way to represent them."""
    notes = []
    humans = [p for p in report.get("players", []) if not p.get("is_bot")]
    dropped = len(report.get("players", [])) - len(humans)
    if dropped:
        notes.append(f"dropped {dropped} bot(s) - no Discord identity")

    matched, unmatched = match_players(humans, roster)

    if unmatched:
        names = ", ".join(repr(p.get("name")) for p in unmatched)
        if not skip_unmatched:
            raise SystemExit(
                c("r", f"\n  refused: {len(unmatched)} player(s) not on the lobby roster: {names}\n") +
                c("d", "  A wrong match credits the wrong Discord account, so nothing was sent.\n"
                       "  Fix with scrims-aliases.json {\"in-game name\": \"roster name\"},\n"
                       "  or pass --skip-unmatched to push only the players that did match.\n"))
        notes.append(f"skipped {len(unmatched)} unmatched: {names}")

    scores = []
    for p, entry, how in matched:
        row = {"score": p.get("score") or {}}
        # discordId is the documented primary; playerId is the fallback the
        # example also accepts.
        if entry.get("discordId"):
            row["discordId"] = str(entry["discordId"])
        elif entry.get("id"):
            row["playerId"] = str(entry["id"])
        else:
            raise SystemExit(c("r", f"  roster entry for {p.get('name')!r} has neither discordId nor id"))
        if p.get("agent"):
            row["agent"] = p["agent"]
        else:
            notes.append(f"{p.get('name')!r} has no resolved agent - field omitted")
        scores.append(row)
        notes.append(f"{p.get('name')!r} -> {row.get('discordId') or row.get('playerId')} ({how})")

    return {"mapId": map_id, "mapIndex": map_index, "playerScores": scores}, notes


# -------------------------------------------------------------------- main

# ------------------------------------------------------------------ watch

# match_ids already pushed, so a report sitting on disk is never sent twice -
# not on a watcher restart, and not because the file was merely re-touched.
PUSHED = os.path.join(KIT, ".scrims-pushed.json")


def load_pushed():
    try:
        with open(PUSHED, encoding="utf-8") as f:
            return set(json.load(f))
    except Exception:
        return set()


def save_pushed(ids):
    # Bounded: a scrim night is a handful of matches, and unbounded growth here
    # would eventually make every watcher tick read a large file.
    with open(PUSHED, "w", encoding="utf-8") as f:
        json.dump(sorted(ids)[-500:], f, indent=2)
        # Trailing newline, for the same reason as everywhere else here.
        f.write("\n")


def push_once(a, key, report):
    """Push one already-loaded final report.

    -> True   the site accepted it
       False  it failed; worth retrying on the next tick
       None   deliberately refused; retrying would not help"""
    roster_path = f"/api/lobbies/{a.lobby}/players"
    status, data = api(a.base_url, roster_path, key)
    roster = (data or {}).get("players", [])
    print(c("d", f"  roster: {len(roster)} player(s) ({status})"))

    map_id, how = (a.map_id, "--map-id") if a.map_id else resolve_map_id(report)
    print(c("d", f"  mapId: {map_id}  ({how})"))

    if a.map_index is not None:
        map_index, how, occupied = a.map_index, "--map-index", False
    else:
        map_index, how, occupied = resolve_map_index(a.base_url, a.lobby, key, map_id)
    print(c("d", f"  mapIndex: {map_index}  ({how})"))

    if occupied and not a.allow_replace:
        print(c("y", f"  refused: lineup slot {map_index} already has scores."))
        print(c("d", "  The watcher will not overwrite a result already on the\n"
                     "  site - if the lineup is finished, this is a map played\n"
                     "  past the end of the scrim. To replace one on purpose,\n"
                     "  push it by hand with --allow-replace."))
        return None

    payload, notes = build_payload(report, roster, map_id, map_index, a.skip_unmatched)
    for n in notes:
        print(c("d", f"    {n}"))

    path = f"/api/lobbies/{a.lobby}/scores"
    try:
        status, _ = api(a.base_url, path, key, "PUT", payload)
        print(c("g", f"  sent {len(payload['playerScores'])} player(s) -> {status}"))
        return True
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        print(c("r", f"  HTTP {e.code}: {redact(detail, key)}"))
        # 4xx is our bug; replaying it would just be rejected again.
        if e.code >= 500:
            print(c("y", f"  queued -> {enqueue({'base': a.base_url, 'path': path, 'payload': payload})}"))
        return False
    except Exception as e:
        print(c("r", f"  {type(e).__name__}: {redact(str(e), key)}"))
        print(c("y", f"  queued -> {enqueue({'base': a.base_url, 'path': path, 'payload': payload})}"))
        return False


def env_lobby():
    """SCRIMS_LOBBY_ID as the .env file says RIGHT NOW, or None.

    Read fresh from disk rather than from os.environ: the watcher is a
    long-lived process and os.environ froze at startup, which is the whole
    problem this exists to catch."""
    path = os.path.join(KIT, ".env")
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == "SCRIMS_LOBBY_ID":
                    return v.strip().strip('"').strip("'") or None
    except OSError:
        pass
    return None


def watch(a, key):
    """Poll the report and push each new final match. The hands-off mode: start
    the server, play, and scores appear on the site."""
    print(c("b", "\n  watching for finished matches"))
    print(c("d", f"  report   {a.report}"))
    print(c("d", f"  lobby    {a.lobby}"))
    print(c("d", f"  every    {a.interval}s   (ctrl-c to stop)\n"))

    pushed = load_pushed()
    if pushed:
        print(c("d", f"  {len(pushed)} match(es) already pushed previously\n"))

    # The lobby this watcher will push to, frozen at startup by argparse. If
    # .env changes underneath a running watcher - which is exactly what
    # starting a new scrim looks like - every score would go to the OLD lobby,
    # silently and irreversibly. Compared against the file on every tick.
    started_with = env_lobby()
    warned_lobby = False

    last_seen = None
    while True:
        try:
            with open(a.report, encoding="utf-8") as f:
                report = json.load(f)
        except FileNotFoundError:
            report = None
        except Exception as e:
            # A half-written file is normal: the mod rewrites it in place. Just
            # try again on the next tick.
            print(c("d", f"  report unreadable ({type(e).__name__}), retrying"))
            report = None

        # Checked before anything is pushed, not after.
        current = env_lobby()
        if current is not None and started_with is not None and current != started_with:
            if not warned_lobby:
                warned_lobby = True
                print(c("r", "\n  STOPPED: SCRIMS_LOBBY_ID changed under a "
                             "running watcher."))
                print(c("d", f"    started with {started_with}\n"
                             f"    .env now says {current}\n"
                             "    This watcher would push to the lobby it "
                             "started with, so it is\n"
                             "    pushing nothing. Restart it:  python "
                             "dimod.py restart <profile>\n"))
            # Non-zero: the watcher stopped without doing its job, so a
            # supervisor sees a failure rather than a clean exit.
            return 1

        if report is not None:
            mid = report.get("match_id")
            if mid and mid != last_seen:
                if not report.get("is_final"):
                    last_seen = mid
                    print(c("d", f"  {mid} still in progress (phase "
                                 f"{report.get('phase')}) - waiting"))
                elif mid in pushed:
                    last_seen = mid
                    print(c("d", f"  {mid} already pushed - skipping"))
                else:
                    print(c("b", f"\n  match {mid}"))
                    print(c("d", f"  {report.get('map_display_name') or report.get('map')}"
                                 f"   {report.get('match_result_name')}"))
                    try:
                        result = push_once(a, key, report)
                        if result is True:
                            pushed.add(mid)
                            save_pushed(pushed)
                            last_seen = mid
                        elif result is None:
                            # Refused on purpose - stop reconsidering it, or
                            # every tick reprints the same refusal.
                            last_seen = mid
                        else:
                            print(c("y", "  will retry on the next tick"))
                    except SystemExit as e:
                        # resolve_map_id / build_payload refuse loudly. Report and
                        # keep watching rather than killing the watcher, so one
                        # bad match does not stop the rest of the night.
                        print(str(e))
                        print(c("y", "  not pushed. Fix the cause (e.g. add the map"))
                        print(c("y", "  to scrims-maps.json) and this retries by itself."))
                    print()

        time.sleep(a.interval)


def main():
    ap = argparse.ArgumentParser(description="push a DIScore report to the scrims site")
    ap.add_argument("--lobby", default=os.environ.get("SCRIMS_LOBBY_ID"),
                    help="lobby id (URL segment); default $SCRIMS_LOBBY_ID")
    ap.add_argument("--map-id", help="the site's map id")
    ap.add_argument("--map-index", type=int, help="position of this map in the lobby")
    ap.add_argument("--report", default=REPORT, help=f"default: {REPORT}")
    ap.add_argument("--base-url", default=os.environ.get("SCRIMS_BASE_URL"))
    ap.add_argument("--roster-file",
                    help="read the roster from a local file shaped like the "
                         "players endpoint instead of fetching it; lets the "
                         "whole matching path be exercised offline")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the exact request and send nothing")
    ap.add_argument("--allow-provisional", action="store_true",
                    help="push a mid-match snapshot (is_final=false)")
    ap.add_argument("--skip-unmatched", action="store_true",
                    help="push matched players only instead of refusing")
    ap.add_argument("--flush", action="store_true", help="retry queued pushes and exit")
    ap.add_argument("--watch", action="store_true",
                    help="poll the report and push each new final match "
                         "automatically; the hands-off mode")
    ap.add_argument("--interval", type=float, default=5.0,
                    help="seconds between polls in --watch (default 5)")
    ap.add_argument("--print-rotation", action="store_true",
                    help="GET the lobby's map lineup and print the matching "
                         "TripwireServer.ini MapRotation value, with maps that "
                         "are already scored removed so position 0 is the next "
                         "map to play. Read-only")
    ap.add_argument("--allow-replace", action="store_true",
                    help="permit writing to a lineup slot that already has "
                         "scores, replacing what is there. Off by default so a "
                         "map played after the lineup is finished cannot "
                         "silently overwrite a completed result")
    ap.add_argument("--full-rotation", action="store_true",
                    help="with --print-rotation, emit the whole lineup instead "
                         "of resuming - use to restart a scrim from map 1")
    ap.add_argument("--print-roster", action="store_true",
                    help="GET the lobby roster, print it, and exit. Read-only - "
                         "the safe way to check auth, base URL, and what the "
                         "roster's 'name' field actually holds")
    a = ap.parse_args()

    key = os.environ.get("SCRIMS_API_KEY")
    if not key and not (a.dry_run and not a.print_roster):
        raise SystemExit(c("r", "  SCRIMS_API_KEY is not set"))

    if a.flush:
        items = queued()
        if not items:
            print(c("d", "  queue is empty"))
            return 0
        for path in items:
            with open(path, encoding="utf-8") as f:
                item = json.load(f)
            try:
                status, _ = api(item["base"], item["path"], key, "PUT", item["payload"])
                print(c("g", f"  sent {os.path.basename(path)} -> {status}"))
                os.remove(path)
            except Exception as e:
                print(c("y", f"  still failing {os.path.basename(path)}: {redact(str(e), key)}"))
        return 0

    if not a.lobby:
        raise SystemExit(c("r", "  --lobby (or SCRIMS_LOBBY_ID) is required"))
    if not a.base_url:
        raise SystemExit(c("r", "  --base-url or SCRIMS_BASE_URL is required"))

    if a.print_rotation:
        try:
            rotation, notes = fetch_rotation(a.base_url, a.lobby, key,
                                             skip_played=not a.full_rotation)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            raise SystemExit(c("r", f"  HTTP {e.code}: {redact(detail, key)}"))
        # Notes to stderr, the value to stdout. A caller then reads stdout
        # whole instead of guessing which line is the answer - dimod used to
        # take the last line of a combined stream, which on an exhausted
        # lineup handed it a NOTE and wrote that into TripwireServer.ini.
        for n in notes:
            print(c("d", "  " + n), file=sys.stderr)
        if not rotation:
            print(c("y", "\n  the scrim is complete - every lineup map is scored.\n"),
                  file=sys.stderr)
            print(c("d", "  Nothing was written; the server keeps its current\n"
                         "  rotation. To replay this lineup from map 1 use\n"
                         "  --full-rotation, or start a new lobby.\n"),
                  file=sys.stderr)
            return EXIT_LINEUP_DONE
        print(",".join(rotation))
        return 0

    if a.print_roster:
        path = f"/api/lobbies/{a.lobby}/players"
        print(c("b", f"\n  GET {a.base_url.rstrip('/')}{path}"))
        try:
            status, data = api(a.base_url, path, key)
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:400]
            raise SystemExit(c("r", f"  HTTP {e.code}: {redact(detail, key)}"))
        except Exception as e:
            raise SystemExit(c("r", f"  {type(e).__name__}: {redact(str(e), key)}"))
        players = (data or {}).get("players", [])
        print(c("d", f"  {status} - {len(players)} player(s)\n"))
        print(json.dumps(data, indent=2, ensure_ascii=False))
        # The open question this answers: is `name` the in-game name or a
        # Discord handle? Folded keys are what the matcher compares on.
        if players:
            print(c("b", "\n  folded match keys (what an in-game name is compared against):"))
            for p in players:
                print(f"    {p.get('name')!r:32} -> {fold(p.get('name'))!r}")
        return 0

    if a.watch:
        # Clear anything a previous run left queued before waiting for new
        # matches, so a site outage self-heals on restart.
        if queued():
            print(c("d", f"  flushing {len(queued())} queued push(es) first"))
            for path in queued():
                with open(path, encoding="utf-8") as f:
                    item = json.load(f)
                try:
                    st, _ = api(item["base"], item["path"], key, "PUT", item["payload"])
                    print(c("g", f"    sent {os.path.basename(path)} -> {st}"))
                    os.remove(path)
                except Exception as e:
                    print(c("y", f"    still failing: {redact(str(e), key)}"))
        return watch(a, key)

    with open(a.report, encoding="utf-8") as f:
        report = json.load(f)

    if not report.get("is_final") and not a.allow_provisional:
        raise SystemExit(c("r",
            f"  refused: report is provisional (phase={report.get('phase')}).\n") +
            c("d", "  Wait for the result screen, or pass --allow-provisional.\n"))

    print(c("b", f"\n  match {report.get('match_id')}"))
    print(c("d", f"  map {report.get('map_display_name') or report.get('map')}"
                 f"   result {report.get('match_result_name')}\n"))

    roster_path = f"/api/lobbies/{a.lobby}/players"
    no_roster = False
    if a.roster_file:
        with open(a.roster_file, encoding="utf-8") as f:
            roster = (json.load(f) or {}).get("players", [])
        print(c("d", f"  roster: {len(roster)} player(s) from {a.roster_file}"))
    elif a.dry_run and not key:
        print(c("y", "  dry run without SCRIMS_API_KEY: cannot fetch the roster,"))
        print(c("y", "  so names cannot be matched. Showing scores only.\n"))
        roster, no_roster = [], True
    else:
        status, data = api(a.base_url, roster_path, key)
        roster = (data or {}).get("players", [])
        print(c("d", f"  roster: {len(roster)} player(s) from {roster_path} ({status})"))

    map_id, how = (a.map_id, "--map-id") if a.map_id else resolve_map_id(report)
    print(c("d", f"  mapId: {map_id}  ({how})"))

    if a.map_index is not None:
        map_index, how, occupied = a.map_index, "--map-index", False
    elif no_roster:
        map_index, how, occupied = 0, "dry run - placeholder", False
    else:
        map_index, how, occupied = resolve_map_index(a.base_url, a.lobby, key, map_id)
    print(c("d", f"  mapIndex: {map_index}  ({how})"))

    if occupied and not a.allow_replace:
        # A dry run still prints the payload below - seeing what WOULD be sent
        # is the point of it - but it must say plainly that a real push is
        # refused, or the preview reads as approval.
        msg = (c("r", f"\n  lineup slot {map_index} already has scores.\n") +
               c("d", "  Pushing would replace a result already on the site. If\n"
                      "  that is what you want, add --allow-replace.\n"))
        if not a.dry_run:
            raise SystemExit(c("r", "  refused:") + msg)
        print(c("y", "  WOULD BE REFUSED:") + msg)

    payload, notes = build_payload(report, roster, map_id, map_index,
                                   a.skip_unmatched or no_roster)
    for n in notes:
        print(c("d", f"    {n}"))

    path = f"/api/lobbies/{a.lobby}/scores"
    print()
    print(c("b", f"  PUT {a.base_url.rstrip('/')}{path}"))
    print(json.dumps(payload, indent=2, ensure_ascii=False))

    if a.dry_run:
        print(c("y", "\n  dry run - nothing sent\n"))
        return 0

    try:
        status, _ = api(a.base_url, path, key, "PUT", payload)
        print(c("g", f"\n  sent -> {status}\n"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        print(c("r", f"\n  HTTP {e.code}: {redact(detail, key)}"))
        # 4xx is our bug, not a transient fault - queueing it would just retry a
        # request the server has already rejected.
        if 500 <= e.code:
            print(c("y", f"  queued -> {enqueue({'base': a.base_url, 'path': path, 'payload': payload})}"))
        return 1
    except Exception as e:
        print(c("r", f"\n  {type(e).__name__}: {redact(str(e), key)}"))
        print(c("y", f"  queued -> {enqueue({'base': a.base_url, 'path': path, 'payload': payload})}"))
        print(c("d", "  retry with:  python tools/scrims_push.py --flush"))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)

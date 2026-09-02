#!/usr/bin/env python3
"""
dimod - Deceive Inc. dedicated-server mod manager.

The kit is the source of truth. Nothing is authored inside the game folder;
`apply` deploys into it and `vanilla` takes it all back out again.

  python dimod.py status              what is deployed / running right now
  python dimod.py list                available mods and profiles
  python dimod.py apply <profile>     deploy a profile into the game folder
  python dimod.py vanilla             restore the game to its stock state
  python dimod.py launch              start the server (no EAC) and inject UE4SS
  python dimod.py stop                stop the server
  python dimod.py restart <profile>   stop, apply, launch
  python dimod.py logs [n]            tail the UE4SS log
  python dimod.py trigger-stage2      toggle the natural-death spectator route
  python dimod.py arm-stage2-spectator
                                      make the next connection a spectator
  python dimod.py force-death         kill your deployed spy -> native spectator
  python dimod.py trigger-native-freemove
                                      toggle the game's native free<->follow spectator
  python dimod.py native-invoke <free|follow>
                                      Gate A: call the spectator toggle UFunction
                                      via the Stage 3 game-thread invoker (DLL)
  python dimod.py native-trace <arm|off>
                                      arm/clear the Stage 3 spectate RPC tracer
  python dimod.py trigger-extraction [player]
                                      arm the carrier-extraction mode; optional
                                      player-name substring picks the carrier
  python dimod.py extraction-recon    dump live extraction/objective state
  python dimod.py grant-loadout [player|all]
                                      fill intel, keycards, powerup chips and
                                      every gadget charge on a deployed spy
  python dimod.py disguise <tier|colour|off> [player]
                                      give an NPC disguise clearance, re-applied
                                      on deploy (purple = technician)
  python dimod.py rescue [player]     teleport a player who fell out of the
                                      world back onto solid ground
  python dimod.py sync-rotation       point MapRotation at the lobby's lineup
  python dimod.py score-report        ask DIScore for a mid-match MP report
  python dimod.py score-log [n]       tail the MP scoring report

With the `scoring` profile applied, `launch` also starts the scrims pusher in
watch mode, so every finished match is scored and pushed with no further input;
`stop` shuts it down again.
"""
import glob, json, os, re, shutil, subprocess, sys, time

KIT = os.path.dirname(os.path.abspath(__file__))
SERVER = r"C:\Program Files (x86)\Steam\steamapps\common\Deceive Inc. Dedicated Server"
WIN64 = os.path.join(SERVER, r"DeceiveInc\Binaries\Win64")
EXE = os.path.join(WIN64, "DeceiveIncServer-Win64-Shipping.exe")
GAME_MODS = os.path.join(WIN64, "Mods")
MODS_TXT = os.path.join(GAME_MODS, "mods.txt")
DICONFIG = os.path.join(WIN64, "DIConfig.ini")
UE4SS_LOG = os.path.join(WIN64, "UE4SS.log")
TRIPWIRE = os.path.join(SERVER, r"DeceiveInc\Saved\Config\WindowsServer\TripwireServer.ini")

KIT_MODS = os.path.join(KIT, "mods")
PROFILES = os.path.join(KIT, "profiles")
BASELINE = os.path.join(KIT, "baseline")
STATE = os.path.join(KIT, ".deployed.json")

# Keys owned by profiles. Applying a profile resets these to the stock baseline
# before applying its overrides, preventing values from a previous profile from
# leaking into the next one. Identity/network keys (ServerName, Password,
# ports, etc.) are deliberately not managed and therefore survive switches.
MANAGED_TRIPWIRE_KEYS = {
    "GameMode", "MaxPlayers", "BotsAmount", "BotsDifficulty",
    "MapRotation", "bIsPublic", "bIsOfficial", "AutoShutdownEmptyMinutes",
    # UTripwireServerSettings also ships a sandbox surface; managed here so a
    # profile switch can never leave sandbox silently enabled.
    "bSandboxMode", "bFillWithBots", "bRandomizeMap",
}

# UE4SS's own bundled mods - left alone by vanilla, they came with the zip
STOCK_MODS = ["CheatManagerEnablerMod", "ActorDumperMod", "ConsoleCommandsMod",
              "ConsoleEnablerMod", "SplitScreenMod", "LineTraceMod", "Keybinds"]

C = {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "b": "\033[1m", "d": "\033[2m", "x": "\033[0m"}
def c(k, s): return f"{C[k]}{s}{C['x']}"


# ---------------------------------------------------------------- helpers

def our_mods():
    if not os.path.isdir(KIT_MODS):
        return []
    return sorted(d for d in os.listdir(KIT_MODS)
                  if os.path.isdir(os.path.join(KIT_MODS, d)))


def profiles():
    if not os.path.isdir(PROFILES):
        return {}
    out = {}
    for f in sorted(os.listdir(PROFILES)):
        if f.endswith(".json"):
            try:
                with open(os.path.join(PROFILES, f), encoding="utf-8") as fh:
                    out[f[:-5]] = json.load(fh)
            except Exception as e:
                print(c("r", f"  ! {f}: {e}"))
    return out


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(d):
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)


def server_pid():
    """Native process lookup. Deliberately no subprocess: the GUI polls this
    every couple of seconds and spawning powershell each time is both slow and
    visible as processes churning in Task Manager."""
    import ctypes
    import ctypes.wintypes as w
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        k32.OpenProcess.restype = w.HANDLE
        k32.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        k32.QueryFullProcessImageNameW.argtypes = [
            w.HANDLE, w.DWORD, ctypes.c_wchar_p, ctypes.POINTER(w.DWORD)]

        arr = (w.DWORD * 8192)()
        need = w.DWORD()
        if not psapi.EnumProcesses(ctypes.byref(arr), ctypes.sizeof(arr), ctypes.byref(need)):
            return None
        for i in range(need.value // ctypes.sizeof(w.DWORD)):
            pid = arr[i]
            if not pid:
                continue
            h = k32.OpenProcess(0x0400, False, pid)   # QUERY_INFORMATION
            if not h:
                continue
            try:
                buf = ctypes.create_unicode_buffer(512)
                size = w.DWORD(512)
                if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                    if buf.value.lower().endswith("deceiveincserver-win64-shipping.exe"):
                        return pid
            finally:
                k32.CloseHandle(h)
    except Exception:
        pass
    return None


def ue4ss_installed():
    return os.path.isfile(os.path.join(WIN64, "ue4ss.dll"))


def read_mods_txt():
    """-> (ordered list of (name, enabled), trailing comment block)"""
    entries, tail = [], []
    if not os.path.isfile(MODS_TXT):
        return entries, tail
    for line in open(MODS_TXT, encoding="utf-8").read().splitlines():
        s = line.strip()
        if not s or s.startswith(";"):
            tail.append(line)
            continue
        if ":" in s:
            n, v = s.split(":", 1)
            entries.append((n.strip(), v.strip() == "1"))
    return entries, tail


def write_mods_txt(enabled_map):
    """Keep stock mods in their original order, put ours first."""
    existing, tail = read_mods_txt()
    known = {n for n, _ in existing}
    lines = []
    for m in our_mods():
        lines.append(f"{m} : {'1' if enabled_map.get(m) else '0'}")
    for n, v in existing:
        if n in our_mods():
            continue
        keep = enabled_map.get(n, v)
        lines.append(f"{n} : {'1' if keep else '0'}")
    for m in STOCK_MODS:
        if m not in known and m not in our_mods():
            lines.append(f"{m} : {'1' if enabled_map.get(m) else '0'}")
    body = "\n".join(lines)
    if tail:
        body += "\n\n" + "\n".join(t for t in tail if t.strip())
    with open(MODS_TXT, "w", encoding="utf-8") as f:
        f.write(body + "\n")


def set_ini_keys(path, updates, section=None):
    """Minimal ini rewrite that preserves unrelated lines.

    A list value is written as REPEATED keys, one line per element, in order.
    That is how UE populates a TArray<FString>, and MapRotation is one.
    Comma-separating them does NOT work - proven 2026-09-02, the server logged

      ignoring MapRotation entry 'A,B,C', no playable map matches
      MapData:DA_MapData_A,B,C

    i.e. it took the whole string as a single entry and fell back to the default
    map pool. docs/01-server-config.md claimed comma-separated and was wrong."""
    def emit(key, value):
        if isinstance(value, (list, tuple)):
            return [f"{key}={item}" for item in value]
        return [f"{key}={value}"]

    lines = []
    if os.path.isfile(path):
        lines = open(path, encoding="utf-8-sig").read().splitlines()
    seen = set()
    out = []
    for line in lines:
        s = line.strip()
        key = s.split("=")[0].strip() if "=" in s and not s.startswith(";") else None
        if key and key in updates:
            # First occurrence becomes the whole (possibly multi-line) value;
            # any later duplicates are dropped, so a shorter rotation cannot
            # leave stale entries behind.
            if key not in seen:
                out.extend(emit(key, updates[key]))
                seen.add(key)
            continue
        out.append(line)
    for k, v in updates.items():
        if k not in seen:
            if section and f"[{section}]" not in "\n".join(out):
                out.append(f"[{section}]")
            out.extend(emit(k, v))
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write("\n".join(out) + "\n")


def remove_ini_keys(path, keys):
    if not os.path.isfile(path):
        return
    lines = open(path, encoding="utf-8-sig").read().splitlines()
    out = [l for l in lines
           if not (("=" in l) and l.split("=")[0].strip() in keys)]
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write("\n".join(out) + "\n")


def read_ini_values(path):
    values = {}
    if not os.path.isfile(path):
        return values
    for line in open(path, encoding="utf-8-sig").read().splitlines():
        s = line.strip()
        if not s or s.startswith((";", "[")) or "=" not in s:
            continue
        k, v = s.split("=", 1)
        values[k.strip()] = v.strip()
    return values


def reset_profile_gameplay_keys():
    """Restore profile-owned keys from baseline without touching identity."""
    orig = os.path.join(BASELINE, "TripwireServer.ini.original")
    baseline = read_ini_values(orig)
    remove_ini_keys(TRIPWIRE, MANAGED_TRIPWIRE_KEYS)
    stock = {k: baseline[k] for k in MANAGED_TRIPWIRE_KEYS if k in baseline}
    if stock:
        set_ini_keys(TRIPWIRE, stock)


# ---------------------------------------------------------------- commands

def cmd_status():
    print(c("b", "\n  Deceive Inc. mod kit\n"))
    pid = server_pid()
    print(f"  server        {c('g','running pid '+str(pid)) if pid else c('d','stopped')}")
    print(f"  UE4SS         {c('g','installed') if ue4ss_installed() else c('r','not installed')}")
    st = load_state()
    print(f"  profile       {c('y', st.get('profile', '(none / vanilla)'))}")
    if st.get("applied_at"):
        print(f"  applied       {c('d', st['applied_at'])}")
    print(f"  launch mode   {c('y', st.get('launch_mode', 'normal'))}")

    print(c("b", "\n  mods"))
    entries, _ = read_mods_txt()
    emap = dict(entries)
    for m in our_mods():
        deployed = os.path.isdir(os.path.join(GAME_MODS, m))
        on = emap.get(m, False)
        mark = c("g", "on ") if (deployed and on) else (c("y", "off") if deployed else c("d", "---"))
        print(f"    {mark}  {m}")

    if os.path.isfile(DICONFIG):
        print(c("b", "\n  DIConfig.ini"))
        for line in open(DICONFIG, encoding="utf-8").read().splitlines():
            if line.strip() and not line.strip().startswith(";"):
                print("    " + line.strip())

    if os.path.isfile(TRIPWIRE):
        print(c("b", "\n  TripwireServer.ini"))
        for line in open(TRIPWIRE, encoding="utf-8-sig").read().splitlines():
            s = line.strip()
            if s and not s.startswith("[") and not s.startswith(";"):
                print("    " + s)
    print()


def cmd_list():
    print(c("b", "\n  mods"))
    for m in our_mods():
        desc = ""
        lua = os.path.join(KIT_MODS, m, "Scripts", "main.lua")
        if os.path.isfile(lua):
            for line in open(lua, encoding="utf-8").read().splitlines()[:4]:
                if line.startswith("--") and len(line) > 4:
                    desc = line.lstrip("- ").strip()
                    break
        print(f"    {c('y', m):<28} {c('d', desc)}")

    print(c("b", "\n  profiles"))
    for name, p in profiles().items():
        print(f"    {c('y', name):<28} {c('d', p.get('description',''))}")
    print()


def cmd_apply(name):
    ps = profiles()
    if name not in ps:
        print(c("r", f"  no such profile: {name}"))
        print("  available: " + ", ".join(ps) if ps else "  (none)")
        return 1
    p = ps[name]
    if not ue4ss_installed() and p.get("mods"):
        print(c("r", "  UE4SS is not installed in the game folder; cannot apply mods."))
        return 1

    print(c("b", f"\n  applying profile: {name}"))
    print(f"  {c('d', p.get('description',''))}\n")

    # One-shot native/Lua markers must never survive a restart or profile
    # switch. They are re-created only by explicit commands/login hooks.
    for transient in ("DINativeSpectator.stage2-trigger",
                      "DINativeSpectator.next-dedicated",
                      "DINativeSpectator.readiness-override",
                      "DINativeSpectator.force-death",
                      "DINativeSpectator.native-freemove",
                      "DINativeSpectator.invoke-request",
                      "DINativeSpectator.invoke",
                      "DINativeSpectator.trace-request",
                      "DINativeSpectator.trace",
                      "DIExtraction.trigger",
                      "DIExtraction.recon",
                      "DIExtraction.loadout",
                      "DIExtraction.disguise",
                      "DIExtraction.rescue",
                      "DIScore.report"):
        transient_path = os.path.join(WIN64, transient)
        if os.path.isfile(transient_path):
            os.remove(transient_path)

    os.makedirs(GAME_MODS, exist_ok=True)
    wanted = p.get("mods", {})

    # deploy every kit mod's files, enable only the requested ones
    for m in our_mods():
        src = os.path.join(KIT_MODS, m)
        dst = os.path.join(GAME_MODS, m)
        if os.path.isdir(dst):
            shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(src, dst)
    enabled = dict(wanted)
    for m in STOCK_MODS:
        enabled.setdefault(m, m in ("CheatManagerEnablerMod", "ConsoleCommandsMod",
                                    "ConsoleEnablerMod", "Keybinds"))
    write_mods_txt(enabled)
    for m in our_mods():
        print(f"    {c('g','on ') if wanted.get(m) else c('d','off')}  {m}")

    # DIConfig.ini
    di = p.get("diconfig")
    if di is not None:
        with open(DICONFIG, "w", encoding="utf-8") as f:
            for section, kv in di.items():
                f.write(f"[{section}]\n")
                for k, v in kv.items():
                    f.write(f"{k} = {v}\n")
                f.write("\n")
        print(f"\n  DIConfig.ini written ({sum(len(v) for v in di.values())} settings)")

    # TripwireServer.ini. Reset our complete gameplay surface first so profile
    # switches are deterministic while ServerName/Password/ports survive.
    reset_profile_gameplay_keys()
    tw = p.get("tripwire")
    if tw:
        set_ini_keys(TRIPWIRE, tw)
        print(f"  TripwireServer.ini: " + ", ".join(f"{k}={v}" for k, v in tw.items()))
    for k in p.get("tripwire_remove", []):
        remove_ini_keys(TRIPWIRE, [k])
        print(f"  TripwireServer.ini: removed {k}")

    save_state({"profile": name,
                "launch_mode": p.get("launch_mode", "normal"),
                "applied_at": time.strftime("%Y-%m-%d %H:%M:%S")})
    print(c("g", "\n  applied. ") + c("d", "restart the server for it to take effect:  python dimod.py restart " + name) + "\n")
    return 0


def cmd_vanilla(remove_ue4ss=False):
    print(c("b", "\n  restoring stock state\n"))
    pid = server_pid()
    if pid:
        cmd_stop()

    for m in our_mods():
        dst = os.path.join(GAME_MODS, m)
        if os.path.isdir(dst):
            shutil.rmtree(dst, ignore_errors=True)
            print(f"    removed mod  {m}")
    if os.path.isfile(MODS_TXT):
        write_mods_txt({m: m in ("CheatManagerEnablerMod", "ConsoleCommandsMod",
                                 "ConsoleEnablerMod", "Keybinds") for m in STOCK_MODS})
        print("    mods.txt reset to UE4SS defaults")
    if os.path.isfile(DICONFIG):
        os.remove(DICONFIG)
        print("    removed DIConfig.ini")
    # Mod output. Globbed rather than listed by name: the previous hard-coded
    # pair named two mods that no longer exist while leaving every current
    # mod's log behind, and orphaned dumps from removed mods accumulated in the
    # game folder. Patterns cover both without needing an edit per mod.
    # DI*.log already covers DINativeSpectator-*.log; overlapping patterns would
    # os.remove an already-removed path and take vanilla down with it.
    for pattern in ("DI*_dump.txt", "DI*.log"):
        for p in sorted(glob.glob(os.path.join(WIN64, pattern))):
            os.remove(p)
            print(f"    removed {os.path.basename(p)}")

    orig = os.path.join(BASELINE, "TripwireServer.ini.original")
    if os.path.isfile(orig):
        # never silently discard hand-edits (ServerName, Password, ports...)
        if os.path.isfile(TRIPWIRE):
            stamp = time.strftime("%Y%m%d-%H%M%S")
            keep = os.path.join(BASELINE, f"TripwireServer.ini.before-vanilla-{stamp}")
            shutil.copyfile(TRIPWIRE, keep)
            print(f"    current config saved -> baseline/{os.path.basename(keep)}")
        shutil.copyfile(orig, TRIPWIRE)
        print("    TripwireServer.ini restored from baseline")
        print(c("y", "    ! this reverts hand-edits too (Password, ServerName, ports)"))
        print(c("d", "      to keep them, use:  python dimod.py apply vanilla"))
    else:
        print(c("y", "    ! no baseline TripwireServer.ini - left as-is"))

    if remove_ue4ss:
        for f in ("ue4ss.dll", "UE4SS-settings.ini", "UE4SS.log", "API.txt",
                  "Readme.md", "Changelog_2_2_0.txt"):
            p = os.path.join(WIN64, f)
            if os.path.isfile(p):
                os.remove(p)
        for d in ("Mods", "UE4SS_Signatures", "MemberVarLayoutTemplates", "VTableLayoutTemplates"):
            p = os.path.join(WIN64, d)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
        print("    UE4SS fully removed")
    else:
        print(c("d", "    UE4SS left installed (inert without mods).  --full to remove it too"))

    save_state({})
    print(c("g", "\n  stock state restored.\n"))


# Written by launch, read by stop. A pid file rather than state in
# .deployed.json, because the watcher's lifetime is tied to a server run and not
# to which profile is deployed.
WATCHER_PID = os.path.join(KIT, ".scrims-watcher.pid")


def python_exe():
    exe = sys.executable
    if os.path.basename(exe).lower() == "pythonw.exe":
        cand = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.isfile(cand):
            return cand
    return exe


EXIT_LINEUP_DONE = 3   # tools/scrims_push.py: the lineup is finished


def sync_scrims_rotation():
    """Point the server's map rotation at the lobby's lineup.

    A mismatched rotation is not a scripting error but it silently breaks
    scoring: the site files a result under the map it expected at that index,
    so a match played on the wrong map never shows up.

    Run at LAUNCH, not at apply: MapRotation and bRandomizeMap are in
    MANAGED_TRIPWIRE_KEYS, so `apply` resets them to baseline first. Launch is
    the last point before the server reads the file.

    -> True   the rotation was written
       None   nothing to do: not a scrims profile, or the lineup is finished
       False  it failed

    None and False are deliberately distinct: a finished scrim is a normal end
    state and must not be reported as an error. Never fatal either way - a
    rotation we could not sync is worth a loud warning, not a refusal to start
    the server."""
    active = load_state().get("profile")
    if not profiles().get(active, {}).get("scrims_watch"):
        return None
    if not os.path.isfile(os.path.join(KIT, ".env")):
        return None

    pusher = os.path.join(KIT, "tools", "scrims_push.py")
    if not os.path.isfile(pusher):
        return None

    print(c("b", "\n  syncing map rotation to the lobby lineup"))
    r = subprocess.run([python_exe(), pusher, "--print-rotation"],
                       capture_output=True, text=True, cwd=KIT)
    # The pusher puts its reasoning on stderr and ONLY the rotation on stdout.
    for line in (r.stderr or "").splitlines():
        print("  " + line)

    if r.returncode == EXIT_LINEUP_DONE:
        print(c("d", "    the server still starts, on whatever rotation it has."))
        return None
    if r.returncode:
        print(c("y", "  ! rotation NOT synced - the server keeps its current one."))
        print(c("d", "    Scores for a map the lobby does not expect will not appear."))
        return False

    rotation = (r.stdout or "").strip()
    if not rotation:
        print(c("y", "  ! lineup returned no maps - rotation left alone"))
        return False

    # A LIST, so set_ini_keys emits one MapRotation= line per map. A single
    # comma-separated line is parsed as one entry and silently discarded.
    entries = [m.strip() for m in rotation.split(",") if m.strip()]

    # Anything that is not a bare map name means the contract above broke, and
    # writing it would corrupt the rotation silently - which is exactly what
    # happened while this read the last line of a combined stream.
    bad = [e for e in entries if not re.fullmatch(r"[A-Za-z0-9_]+", e)]
    if bad:
        print(c("y", f"  ! unexpected rotation output {bad!r} - rotation left alone"))
        return False
    set_ini_keys(TRIPWIRE, {"MapRotation": entries, "bRandomizeMap": "False"})
    for i, m in enumerate(entries):
        print(c("g", f"  MapRotation={m}") + c("d", f"   (map {i})"))
    print(c("d", "  bRandomizeMap=False (round-robin, so match N is lineup map N)"))
    return True


def start_scrims_watcher():
    """Spawn the scrims pusher in --watch mode for profiles that ask for it.

    Opt-in per profile ("scrims_watch": true) so an ordinary profile never
    starts a process that talks to the network. Skipped with an explanation if
    .env is missing, rather than starting a watcher that will only fail."""
    active = load_state().get("profile")
    if not profiles().get(active, {}).get("scrims_watch"):
        return
    if not os.path.isfile(os.path.join(KIT, ".env")):
        print(c("y", "  scrims watcher not started: no .env "
                     "(copy .env.example and fill it in)"))
        return

    pusher = os.path.join(KIT, "tools", "scrims_push.py")
    if not os.path.isfile(pusher):
        print(c("r", "  scrims watcher not started: tools/scrims_push.py missing"))
        return

    exe = sys.executable
    if os.path.basename(exe).lower() == "pythonw.exe":
        cand = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.isfile(cand):
            exe = cand

    # Its own console window: the whole point is that pushes are visible
    # without the user going looking for a log.
    flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
    try:
        proc = subprocess.Popen([exe, pusher, "--watch"], cwd=KIT, creationflags=flags)
    except Exception as e:
        print(c("r", f"  scrims watcher failed to start: {e}"))
        return
    with open(WATCHER_PID, "w", encoding="ascii") as f:
        f.write(str(proc.pid))
    print(c("g", f"  scrims watcher started (pid {proc.pid}) - scores push automatically"))


def stop_scrims_watcher():
    try:
        with open(WATCHER_PID, encoding="ascii") as f:
            pid = int(f.read().strip())
    except Exception:
        return
    os.remove(WATCHER_PID)
    # taskkill rather than ctypes: the watcher owns a console, and its child
    # python process should go with it.
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                   capture_output=True, text=True)
    print(c("d", f"  scrims watcher stopped (pid {pid})"))


def cmd_launch(mode=None):
    if server_pid():
        print(c("y", "  server already running"))
        return
    mode = mode or load_state().get("launch_mode", "normal")
    if mode == "solo12":
        launcher = os.path.join(KIT, "tools", "launch_solo12.py")
        if not os.path.isfile(launcher):
            print(c("r", "  tools/launch_solo12.py missing"))
            return 1
        print(c("b", "\n  launching server with memory-only Solo-12 patch + UE4SS\n"))
        exe = sys.executable
        if os.path.basename(exe).lower() == "pythonw.exe":
            cand = os.path.join(os.path.dirname(exe), "python.exe")
            if os.path.isfile(cand):
                exe = cand
        r = subprocess.run([exe, launcher], capture_output=True, text=True)
        for line in (r.stdout or "").splitlines(): print("  " + line)
        for line in (r.stderr or "").splitlines(): print("  " + line)
        return r.returncode
    if mode != "normal":
        print(c("r", f"  unknown launch mode: {mode}"))
        return 1
    inject = os.path.join(KIT, "tools", "inject.py")
    if not os.path.isfile(inject):
        print(c("r", "  tools/inject.py missing"))
        return 1
    sync_scrims_rotation()
    print(c("b", "\n  launching server (direct exe, no EAC) + injecting UE4SS\n"))
    # capture and re-print, so callers that redirect stdout (the GUI) see it
    exe = sys.executable
    if os.path.basename(exe).lower() == "pythonw.exe":
        cand = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.isfile(cand):
            exe = cand
    active = load_state().get("profile")
    profile = profiles().get(active, {})
    native_modules = profile.get("native_modules", [])
    launch_env = os.environ.copy()
    if any(m in ("DINativeSpectatorStage2", "DINativeSpectatorStage3")
           for m in native_modules):
        launch_env["DIMOD_POST_INJECT_WAIT"] = "0.25"
    r = subprocess.run([exe, inject, "--launch"], capture_output=True, text=True,
                       env=launch_env)
    for line in (r.stdout or "").splitlines():
        print("  " + line)
    for line in (r.stderr or "").splitlines():
        print("  " + line)
    if r.returncode:
        return r.returncode

    # Native DLLs are opt-in and profile-gated. Ordinary profiles have no
    # native_modules key, so the native loader is never invoked for them.
    if any(m in ("DINativeSpectatorStage2", "DINativeSpectatorStage3")
           for m in native_modules):
        loader = os.path.join(KIT, "tools", "load_native_spectator.py")
        native = subprocess.run([exe, loader], capture_output=True, text=True)
        for line in (native.stdout or "").splitlines(): print("  " + line)
        for line in (native.stderr or "").splitlines(): print("  " + line)
        if native.returncode:
            return native.returncode
        start_scrims_watcher()
        return 0
    start_scrims_watcher()
    return 0


def cmd_stop():
    import ctypes
    import ctypes.wintypes as w
    stop_scrims_watcher()
    pid = server_pid()
    if not pid:
        print(c("d", "  server not running"))
        return
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = w.HANDLE
    h = k32.OpenProcess(0x0001, False, pid)          # PROCESS_TERMINATE
    if h:
        k32.TerminateProcess(h, 0)
        k32.WaitForSingleObject(h, 10000)
        k32.CloseHandle(h)
    for _ in range(20):                               # confirm it is really gone
        if server_pid() is None:
            print(c("g", f"  stopped pid {pid}"))
            return
        time.sleep(0.25)
    print(c("y", f"  pid {pid} did not exit"))


def cmd_logs(n=40):
    if not os.path.isfile(UE4SS_LOG):
        print(c("r", "  no UE4SS.log"))
        return
    lines = open(UE4SS_LOG, encoding="utf-8", errors="replace").read().splitlines()
    for l in lines[-int(n):]:
        print("  " + l)


def cmd_trigger_stage2(mode=None):
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.stage2-trigger")
    if mode is not None:
        print(c("r", "  usage: dimod.py trigger-stage2"))
        return 1
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("TRIGGER\n")
    except FileExistsError:
        print(c("r", "  refused: a Stage 2 trigger is already pending"))
        return 1
    print(c("y", f"  Stage 2 natural-spectator free-move toggle armed for dedicated server pid {pid}"))
    return 0


def cmd_force_death():
    """Option C: kill the human's deployed spy so the untouched client drops
    into the game's native death-spectator flow (spectator HUD + A/D follow)."""
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.force-death")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("FORCE DEATH\n")
    except FileExistsError:
        print(c("r", "  refused: a force-death request is already pending"))
        return 1
    print(c("y", f"  force-death armed: your deployed spy will be killed on pid {pid}"))
    return 0


def cmd_trigger_native_freemove():
    """Gate A: toggle the game's own free<->follow spectator via its native
    functions (CheatSpectateFreeMoveSrv / ServerReturnToPlayer), picked by the
    current pawn. Run once to go free, again to return to follow."""
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.native-freemove")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("NATIVE FREEMOVE\n")
    except FileExistsError:
        print(c("r", "  refused: a native-freemove toggle is already pending"))
        return 1
    print(c("y", f"  native free<->follow toggle armed on pid {pid}"))
    return 0


def cmd_native_invoke(direction=None):
    """Gate A via the native game-thread invoker (Stage 3 DLL). Asks the Lua
    resolver to look up the live spectator pawn and the target UFunction, then
    the DLL calls it through UObject::ProcessEvent on the game thread:
      free   -> DISpectatorPawn:CheatSpectateFreeMoveSrv  (follow -> free)
      follow -> DIFreeSpectator:ServerReturnToPlayer      (free -> follow)
    Run after a DebugFreecam return has spawned a fresh acknowledged spectator
    pawn (the case the earlier reflected path never reached)."""
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    if direction not in ("free", "follow"):
        print(c("r", "  usage: dimod.py native-invoke <free|follow>"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.invoke-request")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write(direction + "\n")
    except FileExistsError:
        print(c("r", "  refused: a native-invoke request is already pending"))
        return 1
    print(c("y", f"  native-invoke '{direction}' requested; Lua resolver will "
                 f"emit the invoke marker on pid {pid}"))
    return 0


def cmd_native_trace(mode=None):
    """Arm or clear the Stage 3 spectate tracer. When armed, the Lua resolver
    writes the watched UFunction addresses plus an object byte-range into
    DINativeSpectator.trace; the DLL then logs each matching ProcessEvent call
    with a hexdump of that range, for diffing spectator state across
    natural-follow / freecam / post-return."""
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    if mode not in ("arm", "off"):
        print(c("r", "  usage: dimod.py native-trace <arm|off>"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.trace-request")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write(mode + "\n")
    except FileExistsError:
        print(c("r", "  refused: a native-trace request is already pending"))
        return 1
    print(c("y", f"  native-trace '{mode}' requested on pid {pid}"))
    return 0


def cmd_arm_stage2_spectator():
    if load_state().get("profile") != "native-spectator-stage2":
        print(c("r", "  refused: native-spectator-stage2 is not active"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DINativeSpectator.next-dedicated")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("NEXT DEDICATED\n")
    except FileExistsError:
        print(c("r", "  refused: the next spectator connection is already armed"))
        return 1
    print(c("y", f"  next connection armed as a dedicated spectator on pid {pid}"))
    return 0


def _extraction_gate():
    """Common preconditions for the DIExtraction marker commands."""
    active = load_state().get("profile")
    if not profiles().get(active, {}).get("mods", {}).get("DIExtraction"):
        print(c("r", f"  refused: active profile '{active}' does not enable DIExtraction"))
        return None
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return None
    return pid


def cmd_trigger_extraction(player=None):
    """Arm the carrier-extraction mode. The DIExtraction Lua mod waits for
    VAULT_LOCKED with the carrier deployed, advances one phase via the game's
    own timer-expiry branch, and teleports the carrier to the briefcase. An
    optional player-name substring designates the carrier (default: the first
    human connection)."""
    pid = _extraction_gate()
    if not pid:
        return 1
    marker = os.path.join(WIN64, "DIExtraction.trigger")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write((player or "") + "\n")
    except FileExistsError:
        print(c("r", "  refused: an extraction trigger is already pending"))
        return 1
    who = f"player matching '{player}'" if player else "the first human player"
    print(c("y", f"  extraction mode armed on pid {pid}; carrier = {who}"))
    print(c("d", "  watch DIExtraction.log in the server Win64 folder"))
    return 0


def cmd_extraction_recon():
    """One-shot dump of live phase/objective/briefcase/controller state into
    DIExtraction.log, for verifying the mode's world assumptions."""
    pid = _extraction_gate()
    if not pid:
        return 1
    marker = os.path.join(WIN64, "DIExtraction.recon")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("RECON\n")
    except FileExistsError:
        print(c("r", "  refused: a recon request is already pending"))
        return 1
    print(c("y", f"  recon requested on pid {pid}; see DIExtraction.log"))
    return 0


def cmd_grant_loadout(target=None):
    """Top up a deployed spy's in-match resources to the game's own maximum:
    intel, all four keycards, ammo/health and every gadget/ability charge the
    agent actually uses. Pass a player-name substring, 'all' for every
    connected player, or nothing for the same player the extraction mode would
    designate as carrier. Meta-progression unlocks are NOT affected - those
    live on the account backend, not this server."""
    pid = _extraction_gate()
    if not pid:
        return 1
    marker = os.path.join(WIN64, "DIExtraction.loadout")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write((target or "") + "\n")
    except FileExistsError:
        print(c("r", "  refused: a loadout grant is already pending"))
        return 1
    if target == "all":
        who = "every connected player"
    elif target:
        who = f"player matching '{target}'"
    else:
        who = "the designated carrier (first human player)"
    print(c("y", f"  loadout grant requested on pid {pid} for {who}"))
    print(c("d", "  the target must be DEPLOYED; see DIExtraction.log"))
    return 0


def cmd_disguise(level=None, target=None):
    """Give a deployed spy an NPC disguise clearance via the game's own
    ASpy::CheatDisguiseGiveSecurityLevelSrv. Accepts a tier name
    (civilian/staff/guard/technician/vip), a keycard colour
    (green/blue/purple/orange), a raw 0-4, or 'off' to stop re-applying.
    The level is remembered and re-applied when the carrier deploys, so the
    extraction phase starts with the disguise already on."""
    valid = ("civilian", "staff", "guard", "technician", "vip",
             "green", "blue", "purple", "orange", "off", "0", "1", "2", "3", "4")
    if level is None or level.lower() not in valid:
        print(c("r", "  usage: dimod.py disguise <tier|colour|0-4|off> [player]"))
        print(c("d", "  tiers:  civilian staff guard technician vip"))
        print(c("d", "  colours: green=staff blue=guard purple=technician orange=vip"))
        return 1
    pid = _extraction_gate()
    if not pid:
        return 1
    marker = os.path.join(WIN64, "DIExtraction.disguise")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write(f"{level.lower()} {target or ''}".strip() + "\n")
    except FileExistsError:
        print(c("r", "  refused: a disguise request is already pending"))
        return 1
    if level.lower() == "off":
        print(c("y", f"  disguise auto-apply cleared on pid {pid}"))
    else:
        print(c("y", f"  disguise '{level}' requested on pid {pid}"))
        print(c("d", "  applied now if deployed, and re-applied on next deploy"))
        print(c("d", "  CheatDisguise* is unproven on this build - check "
                     "DIExtraction.log for whether it took effect"))
    return 0


def cmd_rescue(target=None):
    """Teleport a player who has fallen out of the world back onto solid
    ground, anchored on a live NPC's position (an NPC is standing on navmesh by
    definition)."""
    pid = _extraction_gate()
    if not pid:
        return 1
    marker = os.path.join(WIN64, "DIExtraction.rescue")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write((target or "") + "\n")
    except FileExistsError:
        print(c("r", "  refused: a rescue is already pending"))
        return 1
    print(c("y", f"  rescue requested on pid {pid}"))
def cmd_score_report():
    """Ask DIScore for an immediate mid-match report instead of waiting for
    MatchResultsPosted. The mod polls for the marker every 2s."""
    if load_state().get("profile") != "scoring":
        print(c("r", "  refused: the scoring profile is not active"))
        return 1
    pid = server_pid()
    if not pid:
        print(c("r", "  refused: dedicated server is not running"))
        return 1
    marker = os.path.join(WIN64, "DIScore.report")
    try:
        with open(marker, "x", encoding="ascii") as f:
            f.write("REPORT\n")
    except FileExistsError:
        print(c("r", "  refused: a report request is already pending"))
        return 1
    print(c("y", f"  scoring report requested on pid {pid}"))
    print(c("d", "  read it with:  python dimod.py score-log"))
    return 0


def cmd_score_log(n=120):
    """Tail DIScore.log. Separate from `logs` because the scoring output is the
    deliverable, not UE4SS diagnostics."""
    path = os.path.join(WIN64, "DIScore.log")
    if not os.path.isfile(path):
        print(c("r", "  no DIScore.log yet (has the scoring profile run a match?)"))
        return 1
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    for line in lines[-int(n):]:
        print("  " + line.rstrip())
    return 0


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd = a[0]
    if cmd == "status":  return cmd_status()
    if cmd == "list":    return cmd_list()
    if cmd == "apply":
        if len(a) < 2: print(c("r", "  usage: dimod.py apply <profile>")); return 1
        return cmd_apply(a[1])
    if cmd == "vanilla": return cmd_vanilla("--full" in a)
    if cmd == "launch":  return cmd_launch()
    if cmd == "stop":    return cmd_stop()
    if cmd == "restart":
        cmd_stop()
        if len(a) > 1:
            if cmd_apply(a[1]): return 1
        return cmd_launch()
    if cmd == "logs":    return cmd_logs(a[1] if len(a) > 1 else 40)
    if cmd == "trigger-stage2":
        return cmd_trigger_stage2(a[1] if len(a) > 1 else None)
    if cmd == "arm-stage2-spectator": return cmd_arm_stage2_spectator()
    if cmd == "force-death": return cmd_force_death()
    if cmd == "trigger-native-freemove": return cmd_trigger_native_freemove()
    if cmd == "native-invoke":
        return cmd_native_invoke(a[1] if len(a) > 1 else None)
    if cmd == "native-trace":
        return cmd_native_trace(a[1] if len(a) > 1 else None)
    if cmd == "trigger-extraction":
        return cmd_trigger_extraction(a[1] if len(a) > 1 else None)
    if cmd == "extraction-recon":
        return cmd_extraction_recon()
    if cmd == "grant-loadout":
        return cmd_grant_loadout(a[1] if len(a) > 1 else None)
    if cmd == "disguise":
        return cmd_disguise(a[1] if len(a) > 1 else None,
                            a[2] if len(a) > 2 else None)
    if cmd == "rescue":
        return cmd_rescue(a[1] if len(a) > 1 else None)
    if cmd == "sync-rotation":
        # None (nothing to do, lineup finished) is not a failure.
        return 1 if sync_scrims_rotation() is False else 0
    if cmd == "score-report": return cmd_score_report()
    if cmd == "score-log":
        return cmd_score_log(a[1] if len(a) > 1 else 120)
    print(c("r", f"  unknown command: {cmd}"))
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)

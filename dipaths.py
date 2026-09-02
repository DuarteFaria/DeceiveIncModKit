"""Where the dedicated server lives, resolved rather than hardcoded.

This used to be one literal string duplicated in dimod.py and
tools/scrims_push.py, which made the kit unusable on any machine whose Steam
library is not on C:. Both now import from here, so there is one definition.

Resolution order, first hit wins:

  1. DI_SERVER_PATH in the environment (or in the kit's .env)
  2. server_path in the kit's config.json
  3. Steam's own library list - every libraryfolders.vdf path is searched
  4. a couple of conventional install locations

A candidate only counts if the server executable is actually inside it, so a
stale config entry falls through to autodetection instead of half-working.

Nothing here raises on failure. `resolve()` returns a Resolution whose .server
is None, and callers decide: `dimod doctor` reports it, everything else refuses
with an actionable message. Raising at import would break the one command whose
job is to explain what is wrong.
"""
import json, os, re, sys

KIT = os.path.dirname(os.path.abspath(__file__))

# Relative to the server root. Also the proof a candidate is the real thing.
EXE_REL = os.path.join("DeceiveInc", "Binaries", "Win64",
                       "DeceiveIncServer-Win64-Shipping.exe")

INSTALL_DIRNAME = "Deceive Inc. Dedicated Server"
CONFIG = os.path.join(KIT, "config.json")
ENV = os.path.join(KIT, ".env")

ENV_VAR = "DI_SERVER_PATH"


class Resolution:
    """Where the server is, and how that was decided.

    `how` is carried so `doctor` can say "from config.json" rather than just
    printing a path - when a path is wrong, knowing which of four sources
    produced it is most of the fix."""

    def __init__(self, server=None, how=None, tried=None):
        self.server = server
        self.how = how
        self.tried = tried or []

    def __bool__(self):
        return self.server is not None


def _valid(path):
    """A directory is the server root only if the executable is in it."""
    return bool(path) and os.path.isfile(os.path.join(path, EXE_REL))


def _tidy(path):
    """Real casing, so paths from the registry (all lowercase) and from
    libraryfolders.vdf do not print as two different installs."""
    try:
        return os.path.realpath(path)
    except OSError:
        return path


def _from_env():
    raw = os.environ.get(ENV_VAR)
    if raw:
        return os.path.abspath(os.path.expandvars(os.path.expanduser(raw.strip())))
    # The kit's .env is read directly rather than via load_dotenv: dimod.py does
    # not import the pusher, and this must work for both.
    try:
        with open(ENV, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == ENV_VAR:
                    v = v.strip().strip('"').strip("'")
                    if v:
                        return os.path.abspath(os.path.expandvars(
                            os.path.expanduser(v)))
    except FileNotFoundError:
        pass
    return None


def _from_config():
    """Raises ValueError on a config that exists but cannot be read.

    Deliberately not swallowed. Autodetection still runs - resolve() records
    the failure and carries on - but the operator has to be told, because a
    config.json that silently does nothing is the worst outcome here. The
    mistake is nearly always a lone backslash in a Windows path, which is not
    legal JSON."""
    try:
        with open(CONFIG, encoding="utf-8-sig") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None
    except ValueError as e:
        raise ValueError(f"{os.path.basename(CONFIG)} is not valid JSON ({e}). "
                         f"Use forward slashes: C:/path, not C:\\path") from None
    except OSError as e:
        raise ValueError(f"{os.path.basename(CONFIG)} could not be read: {e}") from None
    if not isinstance(data, dict):
        raise ValueError(f"{os.path.basename(CONFIG)} must contain a JSON object")
    raw = (data or {}).get("server_path")
    if isinstance(raw, str) and raw.strip():
        return os.path.abspath(os.path.expandvars(os.path.expanduser(raw.strip())))
    return None


def steam_root():
    """Steam's install directory, from the registry then the usual places."""
    try:
        import winreg
        for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                          (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    for name in ("SteamPath", "InstallPath"):
                        try:
                            val, _ = winreg.QueryValueEx(k, name)
                        except FileNotFoundError:
                            continue
                        if val and os.path.isdir(val):
                            return os.path.normpath(val)
            except OSError:
                continue
    except ImportError:
        pass   # not Windows

    for guess in (r"C:\Program Files (x86)\Steam", r"C:\Program Files\Steam"):
        if os.path.isdir(guess):
            return guess
    return None


def steam_libraries():
    """Every Steam library folder, including the root one.

    libraryfolders.vdf is parsed with a regex rather than a vdf library - the
    only field needed is "path", and a dependency for that is not worth it."""
    root = steam_root()
    if not root:
        return []

    libs = [os.path.join(root, "steamapps")]
    vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
    try:
        with open(vdf, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return libs

    for m in re.finditer(r'"path"\s+"([^"]+)"', text):
        # VDF escapes backslashes.
        p = m.group(1).replace("\\\\", "\\")
        cand = os.path.join(p, "steamapps")
        # Case-insensitively deduped: the registry and the vdf routinely give
        # the same directory with different casing.
        seen = {os.path.normcase(l) for l in libs}
        if os.path.isdir(cand) and os.path.normcase(cand) not in seen:
            libs.append(cand)
    return libs


def _from_steam():
    for lib in steam_libraries():
        cand = os.path.join(lib, "common", INSTALL_DIRNAME)
        if _valid(cand):
            return _tidy(cand)
    return None


def _conventional():
    for base in (r"C:\Program Files (x86)\Steam\steamapps\common",
                 r"C:\Program Files\Steam\steamapps\common"):
        cand = os.path.join(base, INSTALL_DIRNAME)
        if _valid(cand):
            return cand
    return None


def resolve():
    """-> Resolution. Never raises."""
    tried = []

    for label, fn, needs_validation in (
            (f"{ENV_VAR} environment variable", _from_env, True),
            ("server_path in config.json", _from_config, True),
            ("Steam library folders", _from_steam, False),
            ("conventional install path", _conventional, False)):
        try:
            path = fn()
        except ValueError as e:                     # actionable, already worded
            tried.append((label, None, str(e)))
            continue
        except Exception as e:                      # never fatal
            tried.append((label, None, f"{type(e).__name__}: {e}"))
            continue
        if path is None:
            tried.append((label, None, "not set" if needs_validation else "no match"))
            continue
        if _valid(path):
            return Resolution(_tidy(path), label, tried)
        # An explicit setting that does not hold the executable is a mistake
        # worth naming, so record it and keep looking.
        tried.append((label, path, "no server executable there"))

    return Resolution(None, None, tried)


def explain(res):
    """Multi-line, actionable text for a failed resolution."""
    lines = ["  Could not find the Deceive Inc. dedicated server.", "",
             "  Looked at:"]
    for label, path, why in res.tried:
        lines.append(f"    - {label}: {why}" + (f"  [{path}]" if path else ""))
    lines += [
        "",
        "  Fix it with either of:",
        f"    set {ENV_VAR}=D:\\path\\to\\{INSTALL_DIRNAME}",
        '    echo {"server_path": "D:\\\\path\\\\to\\\\server"} > config.json',
        "",
        f"  The path must be the folder CONTAINING {EXE_REL}.",
    ]
    return "\n".join(lines)


# Resolved once per process. A sentinel keeps derived os.path.join calls from
# silently becoming relative paths rooted at the current directory - a missing
# game must never turn into a write next to the kit.
RESOLUTION = resolve()
SERVER = RESOLUTION.server or os.path.join(KIT, ".server-not-found")
FOUND = bool(RESOLUTION)

WIN64 = os.path.join(SERVER, "DeceiveInc", "Binaries", "Win64")
EXE = os.path.join(SERVER, EXE_REL)
TRIPWIRE = os.path.join(SERVER, "DeceiveInc", "Saved", "Config",
                        "WindowsServer", "TripwireServer.ini")
SAVED_LOGS = os.path.join(SERVER, "DeceiveInc", "Saved", "Logs")


if __name__ == "__main__":
    if FOUND:
        print(f"  server   {SERVER}")
        print(f"  via      {RESOLUTION.how}")
        sys.exit(0)
    print(explain(RESOLUTION))
    sys.exit(1)

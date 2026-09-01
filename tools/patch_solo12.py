"""Raise the Solo player cap from 8 to 12 in the dedicated server binary.

WHY A PATCH AT ALL
------------------
MaxPlayers in TripwireServer.ini is not the cap. The server clamps it against a
per-game-mode maximum:

    Solo  -> 8    (1 x 8 teams)
    Duo   -> 10   (2 x 5 teams)
    Trio  -> 12   (3 x 4 teams)

Trio already reaches 12 players and needs no patch - use the `trio-12` profile
if 4 teams of 3 is acceptable. This patch exists only for 12 players in *Solo*,
which is not reachable any other way. Everything else was tried and failed:

  - MaxPlayers is not a reflected property, so UE4SS cannot write it
  - net.MaxPlayersOverride is accepted by the engine and ignored by Tripwire
  - -FactionSize=1 on the command line is read, then overridden by the
    dedicated server's own FactionPlan

WHAT IT CHANGES
---------------
One byte. The clamp maximum is chosen by a branch chain:

    0x10dbe62   41 b9 0c 00 00 00    mov r9d, 12
    0x10dbe6a   41 b9 0a 00 00 00    mov r9d, 10
    0x10dbe72   41 b9 08 00 00 00    mov r9d, 8     <- Solo
    0x10dbe7c   lea rdx, "MaxPlayers"

The 08 becomes 0C. NumTeams is derived as MaxPlayers / TeamSize, so Solo
becomes 12 teams of 1.

SAFETY
------
This is the DEDICATED SERVER binary, which we already launch directly without
EasyAntiCheat - there is no anti-cheat in the process and no ban risk. Never do
anything like this to the client; that one is EAC-protected.

The original is copied to baseline/ before anything is written, and --revert
restores it. A Steam update will replace the exe and silently undo the patch;
rerun --apply afterwards. `verify integrity of game files` also restores it.

USAGE
    python tools/patch_solo12.py --check
    python tools/patch_solo12.py --apply
    python tools/patch_solo12.py --revert
"""
import os
import shutil
import sys

SERVER = (r"C:\Program Files (x86)\Steam\steamapps\common"
          r"\Deceive Inc. Dedicated Server")
EXE = os.path.join(SERVER, r"DeceiveInc\Binaries\Win64"
                           r"\DeceiveIncServer-Win64-Shipping.exe")
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKUP = os.path.join(KIT, "baseline",
                      "DeceiveIncServer-Win64-Shipping.exe.stock")

OFFSET = 0x10DBE74                      # the imm8 of  mov r9d, <max>
STOCK = bytes.fromhex("41b908000000")   # mov r9d, 8
PATCHED = bytes.fromhex("41b90c000000")  # mov r9d, 12


def read_window():
    with open(EXE, "rb") as f:
        f.seek(OFFSET - 2)
        return f.read(6)


def state():
    w = read_window()
    if w == STOCK:
        return "stock", w
    if w == PATCHED:
        return "patched", w
    return "unknown", w


def cmd_check():
    if not os.path.isfile(EXE):
        print("server exe not found:", EXE)
        return 1
    st, w = state()
    print(f"  exe     {EXE}")
    print(f"  offset  {hex(OFFSET)}")
    print(f"  bytes   {w.hex(' ')}")
    print(f"  state   {st}" + {
        "stock": "   (Solo capped at 8)",
        "patched": "   (Solo raised to 12)",
        "unknown": "   <- does NOT match either pattern; do not patch",
    }[st])
    print(f"  backup  {'present' if os.path.isfile(BACKUP) else 'MISSING'}")
    return 0


def server_running():
    """Patching a running exe fails on Windows with a sharing violation, but
    check explicitly so the error is comprehensible rather than an OSError."""
    sys.path.insert(0, KIT)
    try:
        import dimod
        return dimod.server_pid() is not None
    except Exception:
        return False


def cmd_apply():
    st, w = state()
    if st == "patched":
        print("  already patched - nothing to do")
        return 0
    if st == "unknown":
        print(f"  bytes at {hex(OFFSET)} are {w.hex(' ')}, expected "
              f"{STOCK.hex(' ')}")
        print("  the game was probably updated and the offset has moved.")
        print("  ABORTING rather than corrupting the binary.")
        return 1
    if server_running():
        print("  server is running - stop it first:  python dimod.py stop")
        return 1

    os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
    if not os.path.isfile(BACKUP):
        print("  backing up stock exe (~92 MB)...")
        shutil.copyfile(EXE, BACKUP)
        print("  ->", BACKUP)

    with open(EXE, "r+b") as f:
        f.seek(OFFSET)
        f.write(b"\x0c")
    print(f"  patched {hex(OFFSET)}: mov r9d,8 -> mov r9d,12")
    print("  Solo now allows up to 12 players.")
    print("\n  next:  python dimod.py restart solo-12")
    return 0


def cmd_revert():
    if not os.path.isfile(BACKUP):
        print("  no backup at", BACKUP)
        print("  use Steam -> Properties -> Installed Files -> Verify integrity")
        return 1
    if server_running():
        print("  server is running - stop it first:  python dimod.py stop")
        return 1
    shutil.copyfile(BACKUP, EXE)
    print("  restored stock exe from backup")
    return 0


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "--check"
    sys.exit({"--check": cmd_check,
              "--apply": cmd_apply,
              "--revert": cmd_revert}.get(arg, cmd_check)())

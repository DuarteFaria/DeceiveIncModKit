"""Launch the dedicated server with a 12-player Solo cap, patching MEMORY only.

The game files on disk are never touched. This matches how it is done
elsewhere: "modding the server code without modifying the game files".

WHY SUSPENDED
-------------
The clamp runs inside UTripwireDedicatedServerManager::Init, about 0.4s after
launch:

    ClampIntSetting :: Name:MaxPlayers Value:12 Clamped:8 Range:1,8

UE4SS does not inject until ~2.5s, so a Lua mod is far too late, and there is
no reflected property to write anyway. So the process is created SUSPENDED -
the image is mapped but no instruction has executed - the byte is patched in
memory, and only then is the thread resumed.

WHAT IS PATCHED
---------------
One byte. The clamp maximum is picked by a branch chain:

    mov r9d, 12     <- Trio
    mov r9d, 10     <- Duo
    mov r9d, 8      <- Solo      the 08 becomes 0C
    lea rdx, "MaxPlayers"

NumTeams is derived as MaxPlayers / TeamSize, so Solo becomes 12 teams of 1.

The bytes are verified before writing and re-read after, and the patch is
abandoned (leaving a stock server running) if anything does not match, rather
than corrupting a live process.

SAFETY
------
Dedicated server only. We already launch it directly with no EasyAntiCheat in
the process, so there is nothing to trip. Never do this to the client.

Because nothing is written to disk, a Steam update cannot break it and there is
nothing to revert - just launch normally to get a stock server back.

USAGE
    python tools/launch_solo12.py            # launch patched + inject UE4SS
    python tools/launch_solo12.py --no-ue4ss # patch only, skip injection
"""
import ctypes
import ctypes.wintypes as w
import os
import subprocess
import sys
import time

SERVER = (r"C:\Program Files (x86)\Steam\steamapps\common"
          r"\Deceive Inc. Dedicated Server")
WIN64 = os.path.join(SERVER, r"DeceiveInc\Binaries\Win64")
EXE = os.path.join(WIN64, "DeceiveIncServer-Win64-Shipping.exe")
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The per-mode maximum is computed in FIVE places, not one. Patching only the
# first raises the match's real cap (FactionPlan reports 12 teams of 1). These
# other copies also participate in mode-cap setup, but even with all five
# patched EOS still advertises 8 slots: NumPublicConnections is a separate,
# still-unresolved value. The compiler emitted the same
# "if mode==Trio then 12 elif Duo then 10 else 8" chain with different register
# allocations, so all five need the same edit.
#
# Each entry: (tag, instruction file offset, expected instruction bytes,
#              index of the immediate byte within the instruction)
SITES = [
    ("A", 0x10DBE72, "41b908000000",  2),   # mov r9d, 8   - match cap
    ("B", 0x10DE5C5, "bb08000000",    1),   # mov ebx, 8
    ("C", 0x10DFBF7, "b808000000",    1),   # mov eax, 8
    ("D", 0x10EB529, "b808000000",    1),   # mov eax, 8
    ("E", 0x11A8E1A, "c745880800000", 3),   # mov [rbp-0x78], 8
]

# .text: VA 0x1000, raw 0x600
def file_to_rva(off):
    return 0x1000 + (off - 0x600)

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)

k32.VirtualProtectEx.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_size_t,
                                 w.DWORD, ctypes.POINTER(w.DWORD)]
k32.ReadProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_size_t,
                                  ctypes.POINTER(ctypes.c_size_t)]
k32.WriteProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_char_p,
                                   ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_size_t)]
psapi.EnumProcessModulesEx.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD,
                                       ctypes.POINTER(w.DWORD), w.DWORD]

PAGE_EXECUTE_READWRITE = 0x40


class PROCESS_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [("Reserved1", ctypes.c_void_p),
                ("PebBaseAddress", ctypes.c_void_p),
                ("Reserved2", ctypes.c_void_p * 2),
                ("UniqueProcessId", ctypes.c_void_p),
                ("Reserved3", ctypes.c_void_p)]


def image_base(handle):
    """Read ImageBaseAddress out of the PEB.

    EnumProcessModules cannot be used here: on a suspended process the loader
    has not run, so the module list is still empty and it returns nothing.
    The PEB, however, is populated by the kernel at process creation, and
    ImageBaseAddress sits at PEB+0x10 on x64.
    """
    ntdll = ctypes.WinDLL("ntdll")
    ntdll.NtQueryInformationProcess.argtypes = [
        w.HANDLE, ctypes.c_int, ctypes.c_void_p, ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong)]
    pbi = PROCESS_BASIC_INFORMATION()
    ret = ctypes.c_ulong()
    status = ntdll.NtQueryInformationProcess(
        handle, 0, ctypes.byref(pbi), ctypes.sizeof(pbi), ctypes.byref(ret))
    if status != 0 or not pbi.PebBaseAddress:
        return None
    raw = read(handle, pbi.PebBaseAddress + 0x10, 8)
    if not raw or len(raw) != 8:
        return None
    return int.from_bytes(raw, "little")


def read(handle, addr, n):
    buf = ctypes.create_string_buffer(n)
    got = ctypes.c_size_t()
    if not k32.ReadProcessMemory(handle, ctypes.c_void_p(addr), buf, n,
                                 ctypes.byref(got)):
        return None
    return buf.raw[:got.value]


def write(handle, addr, data):
    old = w.DWORD()
    if not k32.VirtualProtectEx(handle, ctypes.c_void_p(addr), len(data),
                                PAGE_EXECUTE_READWRITE, ctypes.byref(old)):
        return False
    put = ctypes.c_size_t()
    ok = k32.WriteProcessMemory(handle, ctypes.c_void_p(addr), data,
                                len(data), ctypes.byref(put))
    restored = w.DWORD()
    k32.VirtualProtectEx(handle, ctypes.c_void_p(addr), len(data), old.value,
                         ctypes.byref(restored))
    return bool(ok) and put.value == len(data)


def main():
    if not os.path.isfile(EXE):
        print("server exe not found:", EXE)
        return 1

    sys.path.insert(0, KIT)
    try:
        import dimod
        if dimod.server_pid():
            print("a server is already running - stop it first:"
                  "  python dimod.py stop")
            return 1
    except Exception:
        pass

    print("launching server SUSPENDED (direct exe, no EAC)...")
    CREATE_SUSPENDED, CREATE_NEW_CONSOLE = 0x00000004, 0x00000010
    p = subprocess.Popen([EXE], cwd=WIN64,
                         creationflags=CREATE_SUSPENDED | CREATE_NEW_CONSOLE)
    pid = p.pid
    print("  pid", pid)

    PROCESS_ALL = 0x1F0FFF
    h = k32.OpenProcess(PROCESS_ALL, False, pid)
    if not h:
        print("  OpenProcess failed:", ctypes.get_last_error())
        return 1

    try:
        base = None
        for _ in range(40):                 # loader maps the image very fast
            base = image_base(h)
            if base:
                break
            time.sleep(0.05)
        if not base:
            print("  could not read image base - resuming unpatched")
            return 1
        print(f"  image base {hex(base)}")

        done, skipped, changed = 0, 0, []
        for tag, off, pat, immoff in SITES:
            expect = bytes.fromhex(pat if len(pat) % 2 == 0 else pat + "0")
            n = len(expect)
            addr = base + file_to_rva(off)
            cur = read(h, addr, n)
            if cur is None:
                print(f"  {tag} {hex(addr)}  read failed - skipped")
                skipped += 1
                continue
            if cur[immoff] == 0x0C:
                print(f"  {tag} {hex(addr)}  already 12")
                continue
            if cur[immoff] != 0x08 or cur[:immoff] != expect[:immoff]:
                print(f"  {tag} {hex(addr)}  {cur.hex(' ')} unexpected "
                      f"(want imm 08) - SKIPPED")
                skipped += 1
                continue
            if not write(h, addr + immoff, b"\x0c"):
                print(f"  {tag} {hex(addr)}  write failed - skipped")
                skipped += 1
                continue
            back = read(h, addr, n)
            if back and back[immoff] == 0x0C:
                print(f"  {tag} {hex(addr)}  {cur.hex(' ')} -> "
                      f"{back.hex(' ')}")
                done += 1
                changed.append(addr + immoff)
            else:
                print(f"  {tag} {hex(addr)}  verify FAILED")
                skipped += 1
        print(f"  patched {done}/{len(SITES)} sites"
              + (f", {skipped} skipped" if skipped else ""))
        if skipped:
            print("  partial patch rejected; restoring changed bytes to stock")
            for addr in changed:
                write(h, addr, b"\x08")
            done = 0
    finally:
        k32.CloseHandle(h)
        # Resume no matter what. A stock server beats a hung suspended one.
        resume(pid)

    print("  resumed")

    if done != len(SITES):
        print("  Solo-12 patch was not applied; server resumed in stock mode")
        return 1

    if "--no-ue4ss" not in sys.argv:
        time.sleep(0.2)
        inject = os.path.join(KIT, "tools", "inject.py")
        exe = sys.executable
        if os.path.basename(exe).lower() == "pythonw.exe":
            cand = os.path.join(os.path.dirname(exe), "python.exe")
            if os.path.isfile(cand):
                exe = cand
        r = subprocess.run([exe, inject], capture_output=True, text=True)
        for line in (r.stdout or "").splitlines():
            print("  " + line)

    print("\n  check it worked:")
    print("    grep 'FactionPlan Seeded' in DeceiveInc/Saved/Logs/"
          "DeceiveInc.log")
    print("    expect  TeamSize:1 NumTeams:12 MaxPlayers:12")
    return 0


def resume(pid):
    """Resume every thread in the process. CreateProcess suspends only the
    primary thread, but enumerate rather than assume."""
    TH32CS_SNAPTHREAD = 0x00000004

    class THREADENTRY32(ctypes.Structure):
        _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD),
                    ("th32ThreadID", w.DWORD), ("th32OwnerProcessID", w.DWORD),
                    ("tpBasePri", ctypes.c_long),
                    ("tpDeltaPri", ctypes.c_long), ("dwFlags", w.DWORD)]

    k32.CreateToolhelp32Snapshot.restype = w.HANDLE
    k32.OpenThread.restype = w.HANDLE
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
    if snap == w.HANDLE(-1).value:
        return
    te = THREADENTRY32()
    te.dwSize = ctypes.sizeof(te)
    ok = k32.Thread32First(snap, ctypes.byref(te))
    while ok:
        if te.th32OwnerProcessID == pid:
            th = k32.OpenThread(0x0002, False, te.th32ThreadID)  # SUSPEND_RESUME
            if th:
                while k32.ResumeThread(th) > 1:
                    pass
                k32.CloseHandle(th)
        ok = k32.Thread32Next(snap, ctypes.byref(te))
    k32.CloseHandle(snap)


if __name__ == "__main__":
    sys.exit(main())

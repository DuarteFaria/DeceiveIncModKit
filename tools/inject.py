"""Inject ue4ss.dll into the Deceive Inc dedicated server.
Usage:
  python inject.py             -> find running server, inject
  python inject.py --launch    -> launch server (no EAC), wait, inject
"""
import ctypes, ctypes.wintypes as w, sys, time, os, subprocess

# The kit root holds dipaths.py; this runs as tools/inject.py, not as a package.
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if KIT not in sys.path:
    sys.path.insert(0, KIT)
import dipaths

EXE = dipaths.EXE
DLL = os.path.join(dipaths.WIN64, "ue4ss.dll")

if not dipaths.FOUND:
    # dimod gates on this before launching, but inject.py is also run by hand.
    raise SystemExit(dipaths.explain(dipaths.RESOLUTION))

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
psapi = ctypes.WinDLL('psapi', use_last_error=True)
k32.OpenProcess.restype = w.HANDLE
k32.VirtualAllocEx.restype = ctypes.c_void_p
k32.VirtualAllocEx.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_size_t, w.DWORD, w.DWORD]
k32.WriteProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_char_p,
                                   ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
k32.GetProcAddress.restype = ctypes.c_void_p
k32.GetProcAddress.argtypes = [w.HANDLE, ctypes.c_char_p]
k32.GetModuleHandleW.restype = w.HANDLE
k32.CreateRemoteThread.restype = w.HANDLE
k32.CreateRemoteThread.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_size_t,
                                   ctypes.c_void_p, ctypes.c_void_p, w.DWORD,
                                   ctypes.POINTER(w.DWORD)]

psapi.GetModuleFileNameExW.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_wchar_p, w.DWORD]
psapi.EnumProcessModulesEx.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD,
                                       ctypes.POINTER(w.DWORD), w.DWORD]

PROCESS_ALL = 0x1F0FFF
MEM_COMMIT_RESERVE = 0x3000
PAGE_RW = 0x04


def find_pid(sub="DeceiveIncServer-Win64-Shipping"):
    arr = (w.DWORD * 8192)(); need = w.DWORD()
    psapi.EnumProcesses(ctypes.byref(arr), ctypes.sizeof(arr), ctypes.byref(need))
    for i in range(need.value // 4):
        pid = arr[i]
        h = k32.OpenProcess(0x0400, False, pid)
        if not h:
            continue
        b = ctypes.create_unicode_buffer(1024); sz = w.DWORD(1024)
        ok = k32.QueryFullProcessImageNameW(h, 0, b, ctypes.byref(sz))
        k32.CloseHandle(h)
        if ok and sub.lower() in b.value.lower():
            return pid
    return None


def modules(pid):
    h = k32.OpenProcess(0x0400 | 0x0010, False, pid)
    arr = (ctypes.c_void_p * 4096)(); need = w.DWORD()
    psapi.EnumProcessModulesEx(h, ctypes.byref(arr), ctypes.sizeof(arr), ctypes.byref(need), 0x03)
    n = need.value // ctypes.sizeof(ctypes.c_void_p)
    out = []
    for i in range(n):
        b = ctypes.create_unicode_buffer(512)
        psapi.GetModuleFileNameExW(h, ctypes.c_void_p(arr[i]), b, 512)
        out.append(os.path.basename(b.value))
    k32.CloseHandle(h)
    return out


def inject(pid, dll):
    h = k32.OpenProcess(PROCESS_ALL, False, pid)
    if not h:
        raise RuntimeError(f"OpenProcess failed: {ctypes.get_last_error()}")
    buf = dll.encode('utf-16-le') + b'\0\0'
    addr = k32.VirtualAllocEx(h, None, len(buf), MEM_COMMIT_RESERVE, PAGE_RW)
    if not addr:
        raise RuntimeError(f"VirtualAllocEx failed: {ctypes.get_last_error()}")
    written = ctypes.c_size_t()
    if not k32.WriteProcessMemory(h, ctypes.c_void_p(addr), buf, len(buf), ctypes.byref(written)):
        raise RuntimeError(f"WriteProcessMemory failed: {ctypes.get_last_error()}")
    llw = k32.GetProcAddress(k32.GetModuleHandleW("kernel32.dll"), b"LoadLibraryW")
    tid = w.DWORD()
    th = k32.CreateRemoteThread(h, None, 0, ctypes.c_void_p(llw), ctypes.c_void_p(addr), 0, ctypes.byref(tid))
    if not th:
        raise RuntimeError(f"CreateRemoteThread failed: {ctypes.get_last_error()}")
    k32.WaitForSingleObject(th, 20000)
    code = w.DWORD()
    k32.GetExitCodeThread(th, ctypes.byref(code))
    k32.CloseHandle(th); k32.CloseHandle(h)
    return code.value


if __name__ == '__main__':
    if '--launch' in sys.argv:
        if find_pid():
            print("server already running; not launching a second one")
        else:
            print("launching server (direct exe, no EAC)...")
            subprocess.Popen([EXE], cwd=os.path.dirname(EXE),
                             creationflags=0x00000010)  # CREATE_NEW_CONSOLE
            for _ in range(120):
                time.sleep(0.1)
                if find_pid():
                    break
    pid = find_pid()
    if not pid:
        print("server process not found - start it first"); sys.exit(1)
    print("server pid", pid)

    # The pregame phase copies DefaultPhaseDuration about 7s after launch. The
    # module list settles around 2.8s, but injecting there can freeze UE4SS in
    # the startup-server -> match-map travel. Eight seconds is stable but misses
    # the phase snapshot. The safe window measured on this build is 5.5-7s:
    # wait for modules to settle, then hold until 5.5s if necessary.
    forced = os.environ.get("DIMOD_INJECT_WAIT")
    if forced:
        print(f"waiting {forced}s (DIMOD_INJECT_WAIT)...")
        time.sleep(float(forced))
    else:
        print("waiting for engine init (module count settling)...")
        last, stable, waited = 0, 0, 0.0
        while waited < 20:
            time.sleep(0.25); waited += 0.25
            try:
                n = len(modules(pid))
            except Exception:
                continue
            if n == last and n > 60:
                stable += 1
                if stable >= 4:            # ~1s with no new DLLs appearing
                    break
            else:
                stable = 0
            last = n
        settled_at = waited
        if waited < 5.5:
            time.sleep(5.5 - waited)
            waited = 5.5
        print(f"  engine settled at {last} modules after {settled_at:.1f}s; "
              f"injecting at {waited:.1f}s")

    mods = modules(pid)
    if any(m.lower() == 'ue4ss.dll' for m in mods):
        print("ue4ss.dll already loaded - nothing to do"); sys.exit(0)

    r = inject(pid, DLL)
    print("LoadLibraryW returned", hex(r), "(nonzero = module handle = success)")
    # Native diagnostic profiles need their exit observer installed before the
    # startup-server map travel. Ordinary profiles retain the proven 3s wait.
    time.sleep(float(os.environ.get("DIMOD_POST_INJECT_WAIT", "3")))
    mods = modules(pid)
    print("ue4ss.dll loaded:", any(m.lower() == 'ue4ss.dll' for m in mods))

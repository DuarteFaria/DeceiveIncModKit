import ctypes, ctypes.wintypes as w, struct, sys, time
import numpy as np
from Crypto.Cipher import AES

PAKS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\Deceive Inc. Dedicated Server\DeceiveInc\Content\Paks\DeceiveInc-WindowsServer.pak",
    r"C:\Program Files (x86)\Steam\steamapps\common\DeceiveInc\DeceiveInc\Content\Paks\DeceiveInc-WindowsNoEditor.pak",
]
probes = []
for P in PAKS:
    f = open(P, 'rb'); f.seek(0, 2); s = f.tell()
    f.seek(s - 221); d = f.read(221)
    io_, isz = struct.unpack('<qq', d[25:41])
    f.seek(io_); probes.append((P, f.read(32))); f.close()

def valid(pt):
    n = struct.unpack('<i', pt[:4])[0]
    if not (2 <= n <= 28):
        return False
    s = pt[4:4 + n]
    if len(s) < n or s[-1] != 0:
        return False
    return all(32 <= c < 127 for c in s[:-1])

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
psapi = ctypes.WinDLL('psapi', use_last_error=True)
PQI, PVR = 0x0400, 0x0010

class MBI(ctypes.Structure):
    _fields_ = [("BaseAddress", ctypes.c_void_p), ("AllocationBase", ctypes.c_void_p),
                ("AllocationProtect", w.DWORD), ("__a", w.DWORD),
                ("RegionSize", ctypes.c_size_t), ("State", w.DWORD),
                ("Protect", w.DWORD), ("Type", w.DWORD), ("__b", w.DWORD)]

k32.OpenProcess.restype = w.HANDLE
k32.VirtualQueryEx.restype = ctypes.c_size_t
k32.ReadProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                                  ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]

def find_pid(sub):
    arr = (w.DWORD * 8192)(); need = w.DWORD()
    psapi.EnumProcesses(ctypes.byref(arr), ctypes.sizeof(arr), ctypes.byref(need))
    for i in range(need.value // 4):
        pid = arr[i]
        h = k32.OpenProcess(PQI, False, pid)
        if not h:
            continue
        buf = ctypes.create_unicode_buffer(1024); sz = w.DWORD(1024)
        ok = k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(sz))
        k32.CloseHandle(h)
        if ok and sub.lower() in buf.value.lower():
            return pid, buf.value
    return None

MAXZ = int(sys.argv[2]) if len(sys.argv) > 2 else 1
ALIGN = int(sys.argv[3]) if len(sys.argv) > 3 else 1

r = find_pid(sys.argv[1] if len(sys.argv) > 1 else "DeceiveIncServer-Win64-Shipping")
if not r:
    print("process not found"); sys.exit(2)
pid, path = r
print("pid", pid, flush=True)
h = k32.OpenProcess(PQI | PVR, False, pid)
if not h:
    print("OpenProcess failed", ctypes.get_last_error()); sys.exit(3)

MEM_COMMIT, MEM_IMAGE = 0x1000, 0x1000000
WRITABLE = {0x04, 0x08, 0x40, 0x80}
regions = []
addr = 0; mbi = MBI()
while k32.VirtualQueryEx(h, ctypes.c_void_p(addr), ctypes.byref(mbi), ctypes.sizeof(mbi)):
    base = mbi.BaseAddress or 0
    if mbi.State == MEM_COMMIT and mbi.Protect in WRITABLE and mbi.RegionSize < 512 * 1024 * 1024:
        regions.append((base, mbi.RegionSize, mbi.Type))
    addr = base + mbi.RegionSize
    if addr > 0x7FFFFFFFFFFF:
        break
regions = [r for r in regions if r[2] != MEM_IMAGE]
print(f"{len(regions)} private regions, {sum(r[1] for r in regions)/1048576:.0f} MB; maxzeros={MAXZ} align={ALIGN}", flush=True)

t0 = time.time(); tested = 0; scanned = 0; last = [0.0]
for base, size, typ in regions:
    buf = (ctypes.c_char * size)(); rd = ctypes.c_size_t()
    if not k32.ReadProcessMemory(h, ctypes.c_void_p(base), buf, size, ctypes.byref(rd)):
        continue
    blob = buf.raw[:rd.value]
    scanned += len(blob)
    if len(blob) < 64:
        continue
    a = np.frombuffer(blob, np.uint8)
    zc = np.cumsum(np.concatenate(([0], (a == 0).astype(np.int32))))
    win = zc[32:] - zc[:-32]                      # zero-count of each 32-byte window
    cand = np.nonzero(win <= MAXZ)[0]
    if ALIGN > 1:
        cand = cand[cand % ALIGN == 0]
    for off in cand.tolist():
        k = blob[off:off + 32]
        tested += 1
        c = AES.new(k, AES.MODE_ECB)
        for pth, pr in probes:
            if valid(c.decrypt(pr)):
                print("\n*** AES KEY FOUND ***")
                print("addr 0x%X" % (base + off))
                print("key: 0x" + k.hex().upper())
                print("pak:", pth)
                print("mount:", c.decrypt(pr)[4:24])
                sys.exit(0)
    now = time.time()
    if now - last[0] > 20:
        last[0] = now
        print(f"  {scanned/1048576:.0f}MB scanned, {tested} AES-tested, {now-t0:.0f}s", flush=True)

print(f"not found; {scanned/1048576:.0f}MB, {tested} tested, {time.time()-t0:.0f}s")

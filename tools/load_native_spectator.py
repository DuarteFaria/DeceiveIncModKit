"""Opt-in Stage 0 loader for DINativeSpectator on the dedicated server only.

This refuses to run unless the exact experimental profile is the deployed
profile and the target process path is the dedicated-server executable. It
never searches for or accepts a Deceive Inc. client process.
"""
import ctypes
import ctypes.wintypes as w
import json
import os
import sys

import inject

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(KIT, ".deployed.json")
# Profiles that may load native DLLs at all. Membership is the gate; the actual
# DLL set comes from the profile's native_modules list via MODULE_DLLS below.
NATIVE_PROFILES = {
    "native-spectator-stage0",
    "native-spectator-stage1",
    "native-spectator-stage2",
}
# Every injectable native module maps to its built DLL name. A profile may list
# more than one (e.g. the readiness override plus the game-thread invoker).
MODULE_DLLS = {
    "DINativeSpectator": "DINativeSpectator.dll",
    "DINativeSpectatorStage1": "DINativeSpectatorStage1.dll",
    "DINativeSpectatorStage2": "DINativeSpectatorStage2.dll",
    "DINativeSpectatorStage3": "DINativeSpectatorStage3.dll",
}
EXPECTED_EXE = os.path.normcase(os.path.abspath(inject.EXE))


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def process_path(pid):
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = w.HANDLE
    k32.QueryFullProcessImageNameW.argtypes = [
        w.HANDLE, w.DWORD, ctypes.c_wchar_p, ctypes.POINTER(w.DWORD)]
    handle = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        raise RuntimeError(f"OpenProcess failed: {ctypes.get_last_error()}")
    try:
        buffer = ctypes.create_unicode_buffer(32768)
        size = w.DWORD(len(buffer))
        if not k32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            raise RuntimeError(f"QueryFullProcessImageNameW failed: {ctypes.get_last_error()}")
        return os.path.normcase(os.path.abspath(buffer.value))
    finally:
        k32.CloseHandle(handle)


def load_one(pid, module_name):
    """Inject a single profile-approved native module. Returns True on success
    (already-loaded counts as success)."""
    dll_name = MODULE_DLLS.get(module_name)
    if not dll_name:
        raise RuntimeError(f"refusing native load: unknown module {module_name}")
    dll = os.path.join(KIT, "native", "DINativeSpectator", "build",
                       "vs2022-x64", "bin", dll_name)
    if not os.path.isfile(dll):
        raise RuntimeError(f"{dll_name} is not built; see docs/09-native-stage0.md")
    if any(name.lower() == dll_name.lower() for name in inject.modules(pid)):
        print(f"{dll_name} already loaded")
        return True
    result = inject.inject(pid, dll)
    if not result:
        raise RuntimeError(f"LoadLibraryW returned null for {dll_name}")
    loaded = any(name.lower() == dll_name.lower() for name in inject.modules(pid))
    print(f"{dll_name} loaded in dedicated server pid {pid}: {loaded}")
    return loaded


def main():
    state = read_json(STATE)
    profile_name = state.get("profile")
    if profile_name not in NATIVE_PROFILES:
        raise RuntimeError("refusing native load: an approved experimental profile is not deployed")
    profile = read_json(os.path.join(KIT, "profiles", profile_name + ".json"))
    modules = [m for m in profile.get("native_modules", []) if m in MODULE_DLLS]
    if not modules:
        raise RuntimeError("refusing native load: no approved module in experimental profile")
    pid = inject.find_pid()
    if not pid:
        raise RuntimeError("dedicated-server process not found")
    actual_exe = process_path(pid)
    if actual_exe != EXPECTED_EXE:
        raise RuntimeError(f"refusing unexpected process path: {actual_exe}")
    # Inject every listed module; report failure if any did not load.
    ok = True
    for module_name in modules:
        ok = load_one(pid, module_name) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"native loader: {error}", file=sys.stderr)
        sys.exit(1)

# Native spectator Stage 0

## Scope and safety boundary

Stage 0 establishes a reproducible x64 workspace and a harmless no-op DLL. It
contains no Unreal hooks, patches, threads, spectator logic, or client code.
The loader accepts only the exact dedicated-server executable path and refuses
to run unless `native-spectator-stage0` is the deployed profile.

Never copy, inject, or install this DLL into the Steam game client. The
EasyAntiCheat-protected client is outside this project's scope. The disarmed
debug-freecam profiles remain disarmed.

## Archived runtime

The exact working runtime is archived under:

`baseline/native-runtime/2026-08-30_56CA5B95_2A03DB20/`

| File | SHA-256 |
|---|---|
| `DeceiveIncServer-Win64-Shipping.exe.archive` | `56CA5B9538117018748ABC7CB3E2AAF42B88BD926D74BC1F1D4278870B64778A` |
| `ue4ss.dll` | `2A03DB20C4F930DFE741DFB028FFB7C51C6465D9AE1F22816CC881D90634581F` |

`manifest.sha256` is the machine-readable source of truth **and the only one of
the three that is committed**. The two binaries are deliberately NOT in the
repo - they are Tripwire's executable and a third-party DLL, neither of which is
ours to redistribute - so on a fresh clone this directory holds the manifest
alone. That costs nothing: both were verified byte-identical to the live install
(and to `baseline/DeceiveIncServer-Win64-Shipping.exe.stock`), so the archive
was only ever a second copy of a file Steam will restore on demand.

To recreate the archive on a machine that needs it, copy the two files in and
check them against the manifest:

```bash
python tools/verify_baseline.py
```

(Not `sha256sum -c` - these manifests are CRLF, which leaves a stray carriage
return on the filename and fails to open it.)

A mismatch means the game updated, in which case the archive is stale and the
Stage 3 offsets in it should not be trusted. To restore the executable without
an archive at all, use Steam's *verify integrity of game files*.

These files are an archive, not deployment inputs; restoring them is a
deliberate manual rollback.
The server binary deliberately has an `.archive` suffix so it cannot be launched
from this incomplete directory. Its content and SHA-256 are unchanged. Copy it
back to the dedicated-server installation and remove only the final `.archive`
suffix if an explicit rollback ever requires it; never run it in `baseline`.

## Native dependencies

- Windows 10/11 x64.
- Visual Studio Build Tools 2022 with
  `Microsoft.VisualStudio.Workload.VCTools` and its recommended Windows SDK.
- CMake 4.4.3 (the project requires CMake 3.21 or newer).
- MSVC x64 Release runtime. The verified DLL imports only `KERNEL32.dll`,
  `VCRUNTIME140.dll`, and `api-ms-win-crt-runtime-l1-1-0.dll`; it has no UE4SS
  or Unreal ABI dependency in Stage 0.
- Python 3, using only the standard library, for the guarded loader.

## Reproducible build and isolated verification

From `native/DINativeSpectator`:

```powershell
& 'C:\Program Files\CMake\bin\cmake.exe' --preset vs2022-x64-release
& 'C:\Program Files\CMake\bin\cmake.exe' --build --preset vs2022-x64-release
& '.\build\vs2022-x64\bin\DINativeSpectatorLoadCycle.exe' `
  '.\build\vs2022-x64\bin\DINativeSpectator.dll'
```

The harness loads the DLL, calls `DINativeSpectatorStage()` (which returns 0),
and unloads it three times. This proves normal Windows load/unload behavior
without touching the running death-spectate server.

Verified Stage 0 build:

- Compiler: MSVC 19.44.35228.0 (`cl` tools directory 14.44.35207).
- Windows SDK: 10.0.26100.0.
- CMake: 4.4.3.
- Architecture: PE x64 (`8664`), with ASLR, NX, and Control Flow Guard.
- DLL SHA-256:
  `DEF5B2E8F1CD0E0205D52D1DBCD8AA0D3D9F42D2351354D51F36645E1D2FE98A`.
- Isolated load/unload harness: three of three cycles passed.
- Guard test under active `death-spectate`: loader refused as designed.
- Python syntax validation for `dimod.py` and the loader: passed.

## Dedicated experimental profile

The DLL is absent from every ordinary profile. To perform a later dedicated
server map-cycle gate deliberately:

```powershell
python dimod.py restart native-spectator-stage0
```

`dimod.py` first launches and injects UE4SS through the existing server-only
path, then calls `tools/load_native_spectator.py`. The loader checks all of:

1. `.deployed.json` names `native-spectator-stage0`;
2. that profile explicitly contains `DINativeSpectator` in `native_modules`;
3. the located process image equals the configured dedicated-server EXE;
4. the DLL comes from this kit's x64 build output.

Do not use this command while an ordinary server session matters; `restart`
stops the current dedicated server.

## Rollback

1. Stop the experimental server: `python dimod.py stop`.
2. Restore the stable profile: `python dimod.py apply death-spectate`.
3. Relaunch when desired: `python dimod.py launch`.
4. To remove build outputs only, delete
   `native/DINativeSpectator/build/`; all source and archived runtime remain.
5. If Steam changes either runtime hash, do not reuse native binaries blindly.
   Archive the new pair, update the manifest, rebuild, and repeat Stage 0.

No rollback step modifies the Steam client. Loading a native DLL cannot be
undone safely in-process by switching profiles; stop the dedicated server first.

## Gate status

The isolated three-cycle DLL load/unload test passed without restarting or
modifying the active `death-spectate` session. The full Stage 0 gate additionally
requires three dedicated-server map cycles under the experimental profile. It
has not been run in this setup and must not be inferred from the isolated test.

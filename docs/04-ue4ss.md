# UE4SS on the dedicated server

## Why injection, not a proxy DLL

The usual UE4SS install drops a proxy DLL next to the game exe. **That cannot
work here**, for two independent reasons:

1. `ue4ss.dll` exports only its own API (`call_script_function`,
   `execute_lua_in_mod`, `is_ue4ss_initialized`, …) — no forwarding exports, so
   it cannot stand in for a system DLL.
2. The server's import table contains neither `dwmapi.dll` nor `xinput1_3.dll`,
   the usual proxy targets. Even correctly named, it would never be loaded.

So `tools/inject.py` launches the server and injects with
`VirtualAllocEx` + `WriteProcessMemory` + `CreateRemoteThread(LoadLibraryW)`.

## Why there is no EAC problem

`inject.py` runs `DeceiveIncServer-Win64-Shipping.exe` **directly**, not the
`DeceiveIncServer.exe` bootstrapper that loads EasyAntiCheat. The server logs

```
DeceiveAntiCheatServer Module isn't loaded, EAC won't be applied.
```

and carries on normally. No anti-cheat is ever in the process.

This is also why none of this touches the game **client** — that one *is*
EAC-protected, and modding it risks a ban. Keep everything server-side.

## Confirmed working configuration

```
UE4SS      v2.4.0 Beta #0, build 6045   (the zip is labelled v2.2.0)
Engine     4.27, auto-detected
```

All signatures resolved from built-in AOBs — no custom signatures needed:

```
StaticConstructObject_Internal    FName::ToString
GUObjectArray                     GMalloc          FName::FName
```

Files live in `DeceiveInc\Binaries\Win64\`: `ue4ss.dll`, `UE4SS-settings.ini`,
`Mods\`, `UE4SS_Signatures\`, `MemberVarLayoutTemplates\`,
`VTableLayoutTemplates\`.

Settings changed from stock: `GuiConsoleEnabled = 1`, `GuiConsoleVisible = 1`.
`[EngineVersionOverride]` left blank — auto-detection gets it right.

`ConsoleEnablerMod` logs `ConsoleClass, GameViewport, or ViewportConsole is
invalid` on startup. That is expected on a headless server and harmless.

## Writing mods

`Mods\<Name>\Scripts\main.lua`, plus a line in `Mods\mods.txt`. The manager
(`dimod.py`) handles both. Full Lua API reference ships as `API.txt` in the
UE4SS zip.

Useful entry points:

```lua
FindAllOf("ClassName")        -- every instance of a class
FindObject(class, name)
ForEachUObject(fn)            -- walk everything (80k-155k objects here)
ExecuteWithDelay(ms, fn)
LoopAsync(ms, fn)

obj:GetFullName()   obj:GetClass()   obj:IsAnyClass()
cls:ForEachProperty(fn)   cls:ForEachFunction(fn)   cls:GetSuperStruct()
prop:GetStruct()    -- StructProperty -> UScriptStruct
prop:GetInner()     -- ArrayProperty  -> element Property
```

**Keybind-driven dumpers are useless here.** UE4SS binds the object dumper to
`J` and it needs window focus, which a headless server does not usefully have.
Drive everything from `ExecuteWithDelay` / `LoopAsync` instead.

## Gotchas

- **Blueprint calls can hard-crash the process, and `pcall` will not catch it.**
  Verify the function exists on the exact class first; prefer stock `AActor`
  functions; log *before* every call so a crash names the culprit.
- `ForEachProperty` returns only a class's *own* properties. Walk
  `GetSuperStruct()` or you will conclude objects are nearly empty.
- Data assets reload on map change, so re-apply overrides periodically —
  `DIConfig` uses a 30-second `LoopAsync`.
- Writes are verified by reading the value back. Do the same in new mods;
  a silent no-op is otherwise indistinguishable from success.

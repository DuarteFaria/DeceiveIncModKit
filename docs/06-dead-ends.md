# Dead ends — read this before repeating any of it

## Pak encryption: not worth attempting again

`DeceiveInc-WindowsServer.pak` (756 MB) and `DeceiveInc-WindowsNoEditor.pak`
(15.4 GB) are UE4 pak **v11** with an **AES-256 encrypted index** and a zero
encryption-key GUID — meaning the key is embedded in the build rather than
supplied externally.

Three exhaustive searches, all negative:

| Search | Coverage | Result |
|---|---|---|
| Static, both executables | 177M offsets, every PE section, 1-byte aligned | nothing |
| Runtime, image-backed pages | 8.7 MB module data, 4.3M candidates | nothing |
| Runtime, heap | 978 MB, 244M candidates | nothing |

Method: AES-decrypt the real pak index's first block with each candidate
32-byte window and validate the mount-point FString — length in range, all
printable, null-terminated. A correct key cannot slip past that test.

Two gaps, stated for honesty: read-only pages were never scanned, and the heap
filter allowed at most one zero byte in the key (roughly a 0.7% chance of a
miss). Neither plausibly explains the result.

**Most likely explanation:** a pak reader only ever *decrypts*, so the code may
retain only the **inverse AES key schedule** and discard the original 32 bytes
after expansion. If so, the key genuinely is not present in the form searched
for. Recovering it would mean locating a 240-byte expanded schedule and
inverting the key expansion — a much larger job.

No published key exists; FModel's key repository has a single unrelated entry.

**Do not repeat this.** The runtime object graph yields the same information
without any of it. See `05-findings.md`.

## What the pak route would have needed anyway

Solved in advance and kept in `tools/`, in case it is ever useful:

- **`pakread.py`** — UE4 v11 reader: AES index decryption, full directory index
  parsing, encoded entry bitfield decoding, Zlib and Oodle. Never tested
  against real data, and one detail of `DecodePakEntry` (block alignment for
  single-block encrypted entries) is an educated guess.
- **Oodle** — Deceive Inc statically links it with no redistributable DLL, but
  `oo2core_9_win64.dll` from another installed game works fine through ctypes.

## Proxy DLLs cannot load UE4SS here

`ue4ss.dll` exports only its own API — no forwarders — and the dedicated server
imports neither `dwmapi.dll` nor `xinput1_3.dll`. No renaming trick will get it
loaded. Injection is required. See `04-ue4ss.md`.

## The balance profile cannot reach gameplay systems

Only 37 spy/weapon tables are managed, with a field allowlist on top of that.
Lobby timing, loot, maps and suspicion are all outside it. See
`02-community-balance.md`.

## The tutorial script cannot be restarted

`Flow_Tutorial_C` exposes one function and zero state variables; its logic is
sealed inside the compiled ubergraph. There is nothing to call. See
`05-findings.md`.

---

## The meta-lesson

The single biggest time sink was assuming the data had to be read **at rest**,
from the pak. It did not. Everything actually needed was sitting decrypted in
the live process's object graph the whole time, reachable through reflection.

When a game encrypts its assets, remember that it must decrypt them to run.

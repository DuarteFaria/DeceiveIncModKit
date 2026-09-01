"""Resolve and disassemble native spectator UFunction entry points.

DINativeStage2 logs live UFunction object addresses. This read-only helper reads
UFunction::Func from the running dedicated server, converts it to an executable
RVA, and prints the entry thunk plus its direct call targets.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes as w
import os
import re
import struct
import sys

import pefile
from iced_x86 import Decoder, Formatter, FormatterSyntax, Mnemonic, OpKind


KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIN64 = (r"C:\Program Files (x86)\Steam\steamapps\common\Deceive Inc. "
         r"Dedicated Server\DeceiveInc\Binaries\Win64")
EXE = os.path.join(WIN64, "DeceiveIncServer-Win64-Shipping.exe")
LOG = os.path.join(WIN64, "DINativeStage2.log")
FUNCTION_RE = re.compile(
    r"ufunction-address path=(?P<path>\S+) object=0x(?P<address>[0-9A-Fa-f]+)")
OBJECT_RE = re.compile(
    r"spectator-object class=(?P<class>\S+) "
    r"object=0x(?P<address>[0-9A-Fa-f]+)")

PROCESS_VM_READ = 0x0010
PROCESS_QUERY_INFORMATION = 0x0400
UFUNCTION_FUNC_OFFSET = 0xD8
NATIVE_EVENT_VTABLE_OFFSET = 0x790

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k32.OpenProcess.restype = w.HANDLE
k32.CloseHandle.argtypes = [w.HANDLE]
k32.ReadProcessMemory.argtypes = [
    w.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_size_t),
]


class PROCESS_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("Reserved1", ctypes.c_void_p),
        ("PebBaseAddress", ctypes.c_void_p),
        ("Reserved2", ctypes.c_void_p * 2),
        ("UniqueProcessId", ctypes.c_void_p),
        ("Reserved3", ctypes.c_void_p),
    ]


def read(handle: w.HANDLE, address: int, size: int) -> bytes:
    buffer = ctypes.create_string_buffer(size)
    received = ctypes.c_size_t()
    if not k32.ReadProcessMemory(
            handle, ctypes.c_void_p(address), buffer, size,
            ctypes.byref(received)):
        error = ctypes.get_last_error()
        raise OSError(error, f"ReadProcessMemory({address:#x}, {size:#x})")
    return buffer.raw[:received.value]


def image_base(handle: w.HANDLE) -> int:
    ntdll = ctypes.WinDLL("ntdll")
    ntdll.NtQueryInformationProcess.argtypes = [
        w.HANDLE, ctypes.c_int, ctypes.c_void_p, ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
    ]
    info = PROCESS_BASIC_INFORMATION()
    returned = ctypes.c_ulong()
    status = ntdll.NtQueryInformationProcess(
        handle, 0, ctypes.byref(info), ctypes.sizeof(info),
        ctypes.byref(returned))
    if status != 0 or not info.PebBaseAddress:
        raise RuntimeError(f"NtQueryInformationProcess failed: {status:#x}")
    return struct.unpack("<Q", read(handle, info.PebBaseAddress + 0x10, 8))[0]


def latest_addresses(path: str) -> tuple[dict[str, int], dict[str, int]]:
    addresses: dict[str, int] = {}
    objects: dict[str, int] = {}
    with open(path, "r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            match = FUNCTION_RE.search(line)
            if match:
                addresses[match.group("path")] = int(match.group("address"), 16)
            match = OBJECT_RE.search(line)
            if match:
                objects[match.group("class")] = int(match.group("address"), 16)
    return addresses, objects


def disassemble(code: bytes, address: int, image_start: int,
                image_end: int) -> tuple[list[str], list[int]]:
    formatter = Formatter(FormatterSyntax.NASM)
    lines: list[str] = []
    calls: list[int] = []
    for index, instruction in enumerate(Decoder(64, code, ip=address)):
        lines.append(f"  {instruction.ip:#018x}  {formatter.format(instruction)}")
        if instruction.mnemonic == Mnemonic.CALL and instruction.op0_kind in (
                OpKind.NEAR_BRANCH16, OpKind.NEAR_BRANCH32,
                OpKind.NEAR_BRANCH64):
            target = instruction.near_branch_target
            if image_start <= target < image_end:
                calls.append(target)
        if instruction.mnemonic == Mnemonic.RET or index >= 79:
            break
    return lines, calls


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int)
    parser.add_argument("--log", default=LOG)
    parser.add_argument("--func-offset", type=lambda value: int(value, 0),
                        default=UFUNCTION_FUNC_OFFSET)
    parser.add_argument("--event-vtable-offset",
                        type=lambda value: int(value, 0),
                        default=NATIVE_EVENT_VTABLE_OFFSET)
    parser.add_argument("--rva", action="append", default=[],
                        type=lambda value: int(value, 0),
                        help="also disassemble an executable RVA")
    args = parser.parse_args()

    sys.path.insert(0, KIT)
    import dimod

    pid = args.pid or dimod.server_pid()
    if not pid:
        raise SystemExit("dedicated server is not running")
    addresses, objects = latest_addresses(args.log)
    if not addresses:
        raise SystemExit("no ufunction-address records; restart Stage 2 first")

    handle = k32.OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
                             False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        base = image_base(handle)
        pe = pefile.PE(EXE, fast_load=True)
        image_end = base + pe.OPTIONAL_HEADER.SizeOfImage
        print(f"pid={pid} image_base={base:#x} image_size={pe.OPTIONAL_HEADER.SizeOfImage:#x}")
        print(f"ufunction_func_offset={args.func_offset:#x}")
        seen_entries: dict[int, str] = {}
        for path, object_address in sorted(addresses.items()):
            raw = read(handle, object_address + args.func_offset, 8)
            entry = struct.unpack("<Q", raw)[0]
            inside = base <= entry < image_end
            rva = entry - base if inside else None
            duplicate = seen_entries.get(entry)
            print(f"\n{path}")
            print(f"  object={object_address:#x} func={entry:#x} "
                  f"rva={rva:#x}" if rva is not None else
                  f"  object={object_address:#x} func={entry:#x} external")
            if duplicate:
                print(f"  same entry as {duplicate}")
            else:
                seen_entries[entry] = path
            if not inside:
                continue
            lines, calls = disassemble(read(handle, entry, 0x300), entry,
                                       base, image_end)
            print("\n".join(lines))
            if calls:
                rendered = ", ".join(f"{target - base:#x}" for target in calls)
                print(f"  direct_call_rvas={rendered}")

        if objects:
            print("\nNative-event vtable slots")
            for class_name, object_address in sorted(objects.items()):
                if class_name == "DIPlayerState":
                    slot_offset = 0x740
                elif class_name in ("DeceiveIncGameModeBase",
                                    "LiveDeceiveIncGameMode"):
                    slot_offset = 0x828
                else:
                    slot_offset = args.event_vtable_offset
                vtable = struct.unpack("<Q", read(handle, object_address, 8))[0]
                target = struct.unpack(
                    "<Q", read(handle, vtable + slot_offset, 8))[0]
                inside = base <= target < image_end
                print(f"\n{class_name}: slot={slot_offset:#x} "
                      f"object={object_address:#x} "
                      f"vtable={vtable:#x} target={target:#x}" +
                      (f" rva={target - base:#x}" if inside else " external"))
                if inside:
                    lines, calls = disassemble(read(handle, target, 0x300),
                                               target, base, image_end)
                    print("\n".join(lines))
                    if calls:
                        rendered = ", ".join(
                            f"{item - base:#x}" for item in calls)
                        print(f"  direct_call_rvas={rendered}")

        for rva in args.rva:
            target = base + rva
            print(f"\nextra-rva={rva:#x} address={target:#x}")
            lines, calls = disassemble(read(handle, target, 0x600), target,
                                       base, image_end)
            print("\n".join(lines))
            if calls:
                rendered = ", ".join(f"{item - base:#x}" for item in calls)
                print(f"  direct_call_rvas={rendered}")
    finally:
        k32.CloseHandle(handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

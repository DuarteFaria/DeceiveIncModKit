"""Locate xrefs to RequestExitWithStatus's diagnostic string in a PE image.

Read-only Stage 1 analysis helper. Requires pefile and capstone.
"""
import os
import argparse
import sys

import pefile
from iced_x86 import Decoder, Formatter, FormatterSyntax

DEFAULT_EXE = (r"C:\Program Files (x86)\Steam\steamapps\common\Deceive Inc. "
               r"Dedicated Server\DeceiveInc\Binaries\Win64"
               r"\DeceiveIncServer-Win64-Shipping.exe")
NEEDLE = "RequestExitWithStatus(%i, %i)".encode("utf-16le") + b"\0\0"


def main(path, needle=NEEDLE):
    pe = pefile.PE(path, fast_load=True)
    data = open(path, "rb").read()
    offset = data.find(needle)
    if offset < 0:
        raise SystemExit("diagnostic string not found")
    rva = pe.get_rva_from_offset(offset)
    target_va = pe.OPTIONAL_HEADER.ImageBase + rva
    print(f"image={path}")
    print(f"image_base={pe.OPTIONAL_HEADER.ImageBase:#x}")
    print(f"string_file_offset={offset:#x} string_rva={rva:#x} string_va={target_va:#x}")

    text = next(section for section in pe.sections
                if section.Name.rstrip(b"\0") == b".text")
    code = data[text.PointerToRawData:text.PointerToRawData + text.SizeOfRawData]
    text_va = pe.OPTIONAL_HEADER.ImageBase + text.VirtualAddress
    decoder = Decoder(64, code, ip=text_va)
    matches = [instruction for instruction in decoder
               if instruction.is_ip_rel_memory_operand and
               instruction.ip_rel_memory_address == target_va]
    if not matches:
        raise SystemExit("no RIP-relative code xref found")
    formatter = Formatter(FormatterSyntax.NASM)
    for instruction in matches:
        instruction_rva = instruction.ip - pe.OPTIONAL_HEADER.ImageBase
        instruction_offset = text.PointerToRawData + instruction.ip - text_va
        print(f"\nxref_va={instruction.ip:#x} xref_rva={instruction_rva:#x}")
        print(f"> {instruction.ip:#x}: {formatter.format(instruction)}")
        pe.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXCEPTION"]])
        runtime = next((entry for entry in pe.DIRECTORY_ENTRY_EXCEPTION
                        if entry.struct.BeginAddress <= instruction_rva <
                        entry.struct.EndAddress), None)
        if runtime:
            begin = runtime.struct.BeginAddress
            end = runtime.struct.EndAddress
            print(f"function_rva={begin:#x} function_end_rva={end:#x}")
            print(f"runtime_unwind_rva={runtime.struct.UnwindData:#x}")
            unwind_offset = pe.get_offset_from_rva(runtime.struct.UnwindData)
            version_flags, _, code_count, _ = data[unwind_offset:unwind_offset + 4]
            flags = version_flags >> 3
            if flags & 0x4:
                chain_offset = unwind_offset + 4 + ((code_count + 1) & ~1) * 2
                chain_begin, chain_end, chain_unwind = __import__("struct").unpack_from(
                    "<III", data, chain_offset)
                print(f"chained_function_rva={chain_begin:#x} "
                      f"chained_function_end_rva={chain_end:#x} "
                      f"chained_unwind_rva={chain_unwind:#x}")
                begin = chain_begin
            start = pe.OPTIONAL_HEADER.ImageBase + begin
            extent = min(end - begin, 0x1000)
        else:
            start = max(text_va, instruction.ip - 96)
            extent = 224
        relative = start - text_va
        nearby = Decoder(64, code[relative:relative + extent], ip=start)
        for item in nearby:
            marker = ">" if item.ip == instruction.ip else " "
            print(f"{marker} {item.ip:#x}: {formatter.format(item)}")
        signature = data[instruction_offset - 16:instruction_offset + instruction.len + 16]
        print(f"xref_context_bytes={signature.hex(' ')}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", default=DEFAULT_EXE)
    parser.add_argument(
        "--needle",
        help="UTF-16LE string to locate instead of RequestExitWithStatus")
    parser.add_argument("--ascii", action="store_true",
                        help="encode --needle as ASCII instead of UTF-16LE")
    parser.add_argument("--no-null", action="store_true",
                        help="do not require a null terminator after --needle")
    args = parser.parse_args()
    terminator = b"" if args.no_null else (b"\0" if args.ascii else b"\0\0")
    encoded = ((args.needle.encode("ascii") + terminator)
               if args.needle and args.ascii else
               (args.needle.encode("utf-16le") + terminator)
               if args.needle else NEEDLE)
    main(os.path.abspath(args.path), encoded)

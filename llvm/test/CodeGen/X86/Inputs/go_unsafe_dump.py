#!/usr/bin/env python3
"""Dump Go PCDATA_UnsafePoint ranges from a relocatable ELF64 x86-64 object.

The TangoLLVM assembler emits per-function ``<func>..pcunsafepoint`` labels into
the ``.goaux`` section.  Each table is a sequence of ULEB128 pairs
(zig-zag value delta, PC delta) terminated by a (0, 0) pair, exactly like Go
runtime pcdata.  This helper parses the ELF symbol table without third-party
modules and prints one line per encoded range, e.g.

  barrier_succ_tail: [0, 9) -1
  barrier_succ_tail: [9, 23) -2
  barrier_succ_tail: [23, 37) -1

Usage: go_unsafe_dump.py <object.o> [func ...]
With no func argument, every ``..pcunsafepoint`` symbol is dumped.
"""
import struct
import sys
from pathlib import Path


def uleb(data, pos):
    result = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return result, pos
        shift += 7


def zigzag(value):
    return (value >> 1) ^ -(value & 1)


def main():
    raw = Path(sys.argv[1]).read_bytes()
    if raw[:6] != b"\x7fELF\x02\x01":
        sys.exit("error: expected little-endian ELF64")
    wanted = set(sys.argv[2:])
    off = struct.unpack_from("<Q", raw, 40)[0]
    size, count, names = struct.unpack_from("<HHH", raw, 58)
    headers = [
        struct.unpack_from("<IIQQQQIIQQ", raw, off + i * size)
        for i in range(count)
    ]
    shstr = headers[names]
    strings = raw[shstr[4]:shstr[4] + shstr[5]]
    sections = {}
    for h in headers:
        name = strings[h[0]:].split(b"\0", 1)[0].decode()
        sections[name] = h

    symbols = {}
    for h in headers:
        if h[1] != 2:  # SHT_SYMTAB
            continue
        link = headers[h[6]]
        strtab = raw[link[4]:link[4] + link[5]]
        for pos in range(h[4], h[4] + h[5], h[9]):
            st_name, st_info, st_other, st_shndx, st_value, st_size = \
                struct.unpack_from("<IBBHQQ", raw, pos)
            name = strtab[st_name:].split(b"\0", 1)[0].decode()
            if name.endswith("..pcunsafepoint"):
                func = name[: -len("..pcunsafepoint")]
                symbols[func] = st_value

    goaux = sections.get(".goaux")
    if goaux is None:
        sys.exit("error: no .goaux section")
    base, section_size = goaux[4], goaux[5]

    for func in sorted(symbols):
        if wanted and func not in wanted:
            continue
        pos = base + symbols[func]
        end = base + section_size
        pc = 0
        value = -1  # PCDATA_UnsafePointSafe
        rows = []
        while pos < end:
            value_delta, pos = uleb(raw, pos)
            pc_delta, pos = uleb(raw, pos)
            if pc_delta == 0:
                break
            next_pc = pc + pc_delta
            value += zigzag(value_delta)
            rows.append((pc, next_pc, value))
            pc = next_pc
        for start, stop, val in rows:
            print(f"{func}: [{start}, {stop}) {val}")
        if not rows:
            print(f"{func}: <empty>")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Dump the Go source PC tables of a relocatable ELF64 x86-64 object.

The TangoLLVM AsmPrinter emits ``<func>..pcfile1``, ``<func>..pcline1`` and
``<func>..pcinline1`` into the ``.goaux`` section. Each is a sequence of
little-endian (uint32 end offset, int32 value) pairs. Like the Go patcher
(cmd/internal/llvm packSourcePCData), this helper drops empty spans and merges
adjacent spans with the same value, then prints one line per table with the
resulting values in PC order, for example

  fill line: 10 11 30 31 13 20 14 15

Usage: go_source_dump.py <object.o> [func ...]
"""
import struct
import sys
from pathlib import Path

TABLES = (("file", "..pcfile1"), ("line", "..pcline1"), ("inline", "..pcinline1"))


def main():
    raw = Path(sys.argv[1]).read_bytes()
    if raw[:6] != b"\x7fELF\x02\x01":
        sys.exit("error: expected little-endian ELF64")
    wanted = sys.argv[2:]
    off = struct.unpack_from("<Q", raw, 40)[0]
    size, count, names = struct.unpack_from("<HHH", raw, 58)
    headers = [struct.unpack_from("<IIQQQQIIQQ", raw, off + i * size)
               for i in range(count)]
    shstr = headers[names]
    strings = raw[shstr[4]:shstr[4] + shstr[5]]
    goaux_index = next((i for i, h in enumerate(headers)
                        if strings[h[0]:].split(b"\0", 1)[0] == b".goaux"), None)
    if goaux_index is None:
        sys.exit("error: no .goaux section")
    goaux = headers[goaux_index]
    base, end = goaux[4], goaux[4] + goaux[5]

    symbols = {}
    for h in headers:
        if h[1] != 2:  # SHT_SYMTAB
            continue
        link = headers[h[6]]
        strtab = raw[link[4]:link[4] + link[5]]
        for pos in range(h[4], h[4] + h[5], h[9]):
            st_name, _, _, st_shndx, st_value, _ = struct.unpack_from("<IBBHQQ", raw, pos)
            if st_shndx == goaux_index:
                symbols[strtab[st_name:].split(b"\0", 1)[0].decode()] = st_value
    # Each table ends where the next .goaux symbol starts.
    starts = sorted(set(symbols.values()))

    funcs = wanted or sorted({n[: -len(s)] for n in symbols for _, s in TABLES
                              if n.endswith(s)})
    for func in funcs:
        for label, suffix in TABLES:
            start = symbols.get(func + suffix)
            if start is None:
                print(f"{func} {label}: <none>")
                continue
            stop = next((s for s in starts if s > start), end - base)
            pos, values, last_end = base + start, [], 0
            while pos + 8 <= base + stop:
                pc_end, value = struct.unpack_from("<Ii", raw, pos)
                pos += 8
                if pc_end < last_end:
                    sys.exit(f"error: {func}{suffix}: PC moves backwards")
                if pc_end == last_end:
                    continue
                if not values or values[-1] != value:
                    values.append(value)
                last_end = pc_end
            print(f"{func} {label}: " + " ".join(map(str, values)))


if __name__ == "__main__":
    main()

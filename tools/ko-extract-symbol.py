#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later OR MIT
"""Extract the raw bytes of a data symbol from an (unrelocated) ELF .ko file.

Usage: ko-extract-symbol.py MODULE.ko SYMBOL OUTPUT
"""
import struct, sys

def main(path, symbol, out):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 2, "64-bit ELF expected"
    shoff, = struct.unpack_from("<Q", d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shentsize) for i in range(shnum)]
    symtab = next(s for s in secs if s[1] == 2)  # SHT_SYMTAB
    strtab = secs[symtab[6]]
    for i in range(symtab[5] // 24):
        name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", d, symtab[4] + i * 24)
        n = d[strtab[4] + name:d.index(b"\0", strtab[4] + name)].decode()
        if n == symbol:
            sec = secs[shndx]
            data = d[sec[4] + value:sec[4] + value + size]
            open(out, "wb").write(data)
            print(f"{symbol}: {size} bytes from section {shndx} -> {out}")
            return
    sys.exit(f"symbol {symbol} not found")

if __name__ == "__main__":
    main(*sys.argv[1:4])

#!/usr/bin/env python3
"""Test machine: disassembles an x86-64 ELF between two virtual addresses (Capstone, Intel syntax).
  tools/disas.py BINARY START END"""
import struct
import sys

import capstone

path, start, end = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
data = open(path, "rb").read()
phoff, phsz, phnum = struct.unpack_from("<Q", data, 0x20)[0], *struct.unpack_from("<HH", data, 0x36)
for i in range(phnum):
    typ, _, off, vaddr, _, filesz = struct.unpack_from("<IIQQQQ", data, phoff + i * phsz)
    if typ == 1 and vaddr <= start < vaddr + filesz:
        code = data[off + start - vaddr:off + min(end, vaddr + filesz) - vaddr]
        for insn in capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64).disasm(code, start):
            print(f"{insn.address:8x}  {insn.mnemonic} {insn.op_str}")
        break

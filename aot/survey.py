#!/usr/bin/env python3
# Which instruction forms a set of functions of an x86-64 binary uses: mnemonic with operand kinds, counted, plus the
# instructions a lifter has to look at closely (indirect jumps and calls, rsp/rbp used as data, fs/gs, lock, rep).
#   aot/survey.py BINARY FUNCTION ...
import subprocess
import sys
from collections import Counter

import capstone
from capstone import x86

binary, funcs = sys.argv[1], sys.argv[2:]
data = open(binary, "rb").read()
# PT_LOAD segments: vaddr -> file offset
import struct
phoff, = struct.unpack_from("<Q", data, 0x20)
phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
segs = []
for i in range(phnum):
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize)
    if p_type == 1:
        segs.append((p_vaddr, p_offset, p_filesz))


def read(addr, n):
    for v, o, s in segs:
        if v <= addr and addr + n <= v + s:
            return data[o + addr - v:o + addr - v + n]
    raise KeyError(hex(addr))


syms = {}
for l in subprocess.run(["nm", "-S", binary], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) == 4 and p[2] in "tTwW":
        syms[p[3]] = (int(p[0], 16), int(p[1], 16))

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
forms = Counter()
notes = []


def kind(op, insn):
    if op.type == x86.X86_OP_REG:
        return "r%d" % (op.size * 8)
    if op.type == x86.X86_OP_IMM:
        return "i"
    m = op.mem
    base = insn.reg_name(m.base) if m.base else ""
    return "m%d" % (op.size * 8) + ("[sp]" if base == "rsp" else "[rip]" if base == "rip" else "")


for f in funcs:
    start, size = syms[f]
    for insn in md.disasm(read(start, size), start):
        k = insn.mnemonic + " " + ",".join(kind(o, insn) for o in insn.operands)
        forms[k] += 1
        txt = f"{f}+{insn.address - start:#x} {insn.address:#x}: {insn.mnemonic} {insn.op_str}"
        if insn.mnemonic in ("jmp", "call", "notrack jmp") and insn.operands and insn.operands[0].type != x86.X86_OP_IMM:
            notes.append("indirect " + txt)
        if insn.mnemonic.startswith(("lock", "rep", "xchg", "cmpxchg", "xadd")) or insn.prefix[0] in (0xf0, 0xf2, 0xf3) and insn.mnemonic not in ("ret", "bnd jmp"):
            notes.append("prefix " + txt)
        for o in insn.operands:
            if o.type == x86.X86_OP_MEM and o.mem.segment:
                notes.append("segment " + txt)
        if insn.mnemonic == "lea" and insn.operands[1].mem.base in (x86.X86_REG_RSP, x86.X86_REG_RBP):
            notes.append("frame address " + txt)
        if insn.mnemonic not in ("push", "pop", "sub", "add", "lea", "and") and any(
                o.type == x86.X86_OP_REG and o.reg in (x86.X86_REG_RSP, x86.X86_REG_RBP) for o in insn.operands):
            notes.append("rsp/rbp as value " + txt)
        if insn.mnemonic in ("sub", "add", "and") and insn.operands[0].type == x86.X86_OP_REG and insn.operands[0].reg == x86.X86_REG_RSP \
                and insn.operands[1].type != x86.X86_OP_IMM:
            notes.append("dynamic rsp " + txt)

for k, n in sorted(forms.items(), key=lambda x: (-x[1], x[0])):
    print(f"{n:5d}  {k}")
print()
for n in notes:
    print(n)

#!/usr/bin/env python3
# Ahead-of-time translation of x86-64 functions into C, compiled for the host by clang (tso-arm prototype).
#   aot/lift.py BINARY OUT.c FUNCTION...
#
# Each named function of the (static, non-PIE) binary becomes a C function that follows the System V calling
# convention: the six argument registers come in as parameters, rax goes out as the result, stack arguments are read
# through a pointer to the caller's outgoing area. Guest registers are C locals, so callee-saved registers keep their
# values across calls by construction, and clang allocates them to host registers. Calls between translated functions
# are C calls; calls to anything else go back into the guest through FEX (aot.h: guest_call).
#
# Memory:
# - Stack slots whose address never leaves the function (the lifter's escape analysis: no lea of the stack pointer
#   reaches them) are a local array; clang turns them into registers. They are invisible to other threads, so their
#   order does not matter.
# - Stack objects whose address is taken stay where the x86 code has them, on the guest stack.
# - All other memory is guest memory, reached through the thread's plain view (aot_ctx.view) with volatile accesses:
#   they keep their program order in the host code, and the page protocol orders them against other threads exactly
#   as it does for FEX's own plain accesses (shared pages fault and are completed in the handler, with barriers).
# - Constants in read-only segments are read at translation time.
#
# Flags are C locals written by every flag-setting instruction (clang removes the unused ones); a condition used in
# the same basic block as its compare is computed from the compared values directly.
import struct
import subprocess
import sys

import capstone
from capstone import x86 as X

M64 = (1 << 64) - 1
T = {8: "uint8_t", 16: "uint16_t", 32: "uint32_t", 64: "uint64_t", 128: "u128"}
S = {8: "int8_t", 16: "int16_t", 32: "int32_t", 64: "int64_t"}


def mask(bits):
    return (1 << bits) - 1


class LiftError(Exception):
    pass


class Elf:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        phoff, = struct.unpack_from("<Q", self.data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", self.data, 0x36)
        self.segs = []
        for i in range(phnum):
            p_type, p_flags, p_offset, p_vaddr, _, p_filesz, p_memsz, _ = struct.unpack_from("<IIQQQQQQ", self.data, phoff + i * phentsize)
            if p_type == 1:
                self.segs.append((p_vaddr, p_offset, p_filesz, p_memsz, p_flags))
        # position-independent (ET_DYN: static-pie or a PIE linked dynamically): loaded at an address known only at run
        # time; the translation then forms every address of the program from aot_base, which FEX sets
        self.pie = struct.unpack_from("<H", self.data, 0x10)[0] == 3
        self.relocs = self.relocated_slots()
        self.syms = {}
        self.all = {}  # name -> every (address, size): static functions of different files may share a name
        for line in subprocess.run(["nm", "-S", path], capture_output=True, text=True).stdout.splitlines():
            p = line.split()
            if len(p) == 4 and p[2] in "tTwW":
                self.syms[p[3]] = (int(p[0], 16), int(p[1], 16))
                self.all.setdefault(p[3], []).append((int(p[0], 16), int(p[1], 16)))

    def lookup(self, spec):
        # NAME, or NAME@ADDRESS for a name several functions share
        name, _, at = spec.partition("@")
        cands = self.all.get(name, [])
        if at:
            cands = [c for c in cands if c[0] == int(at, 16)]
        if len(cands) != 1:
            raise LiftError(f"{spec}: {len(cands)} functions of that name"
                            + (" (" + ", ".join(f"{name}@{a:#x}" for a, s in self.all.get(name, [])) + ")" if cands else ""))
        return name, cands[0]

    def read(self, addr, n):
        for v, o, fs, ms, fl in self.segs:
            if v <= addr and addr + n <= v + fs:
                return self.data[o + addr - v:o + addr - v + n]
        raise LiftError(f"no file data at {addr:#x}")

    def readonly(self, addr, n=1):
        # in a loaded segment without write permission (RELRO data counts as writable here)
        for v, o, fs, ms, fl in self.segs:
            if v <= addr and addr + n <= v + fs:
                return not (fl & 2)
        return False

    def relocated_slots(self):
        # the 8-byte slots the loader writes (RELA and RELR sections): their file contents are not what the program
        # reads, so no load from them may be folded into a constant
        slots = set()
        shoff, = struct.unpack_from("<Q", self.data, 0x28)
        shentsize, shnum = struct.unpack_from("<HH", self.data, 0x3A)
        for i in range(shnum if shoff else 0):
            _, sh_type, _, _, off, size, _, _, _, entsize = struct.unpack_from("<IIQQQQIIQQ", self.data, shoff + i * shentsize)
            if sh_type == 4 and entsize == 24:  # SHT_RELA
                for k in range(size // 24):
                    slots.add(struct.unpack_from("<Q", self.data, off + 24 * k)[0])
            elif sh_type == 19:  # SHT_RELR: an address, then bitmaps of the 63 slots after it
                base = 0
                for k in range(size // 8):
                    e, = struct.unpack_from("<Q", self.data, off + 8 * k)
                    if not e & 1:
                        slots.add(e)
                        base = e + 8
                    else:
                        for b in range(63):
                            if (e >> (b + 1)) & 1:
                                slots.add(base + 8 * b)
                        base += 63 * 8
        return slots

    def relocated(self, addr, n):
        return any(s < addr + n and addr < s + 8 for s in range(addr - 7, addr + n) if s in self.relocs)


def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & M64
    return h


# register name -> (C variable, bits, high byte)
REGS = {}
for base, names in {
    "rax": ("eax", "ax", "al", "ah"), "rcx": ("ecx", "cx", "cl", "ch"), "rdx": ("edx", "dx", "dl", "dh"),
    "rbx": ("ebx", "bx", "bl", "bh"), "rsp": ("esp", "sp", "spl", None), "rbp": ("ebp", "bp", "bpl", None),
    "rsi": ("esi", "si", "sil", None), "rdi": ("edi", "di", "dil", None),
}.items():
    REGS[base] = (base, 64, False)
    REGS[names[0]] = (base, 32, False)
    REGS[names[1]] = (base, 16, False)
    REGS[names[2]] = (base, 8, False)
    if names[3]:
        REGS[names[3]] = (base, 8, True)
for i in range(8, 16):
    REGS[f"r{i}"] = (f"r{i}", 64, False)
    REGS[f"r{i}d"] = (f"r{i}", 32, False)
    REGS[f"r{i}w"] = (f"r{i}", 16, False)
    REGS[f"r{i}b"] = (f"r{i}", 8, False)
for i in range(16):
    REGS[f"xmm{i}"] = (f"x{i}", 128, False)
    REGS[f"ymm{i}"] = (f"x{i}", 256, False)  # low half in xN, high half in yN
GPRS = ["rax", "rcx", "rdx", "rbx", "rbp", "rsi", "rdi"] + [f"r{i}" for i in range(8, 16)]
ARGS = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]

CC = {"o": "o", "no": "no", "b": "b", "c": "b", "nae": "b", "ae": "ae", "nb": "ae", "nc": "ae", "e": "e", "z": "e",
      "ne": "ne", "nz": "ne", "be": "be", "na": "be", "a": "a", "nbe": "a", "s": "s", "ns": "ns", "p": "p", "pe": "p",
      "np": "np", "po": "np", "l": "l", "nge": "l", "ge": "ge", "nl": "ge", "le": "le", "ng": "le", "g": "g", "nle": "g"}


def cc_of(mnemonic, prefix):
    c = mnemonic[len(prefix):]
    if c not in CC:
        raise LiftError(f"condition {mnemonic}")
    return CC[c]


class Function:
    def __init__(self, elf, spec):
        self.elf = elf
        if "=" in spec:
            # NAME=ENTRY:START:END (hex): code from START to END entered at ENTRY, jumps anywhere inside it internal
            # (glibc's string functions: several entry points into shared bodies)
            name, rng = spec.split("=", 1)
            self.start, lo, hi = (int(x, 16) for x in rng.split(":"))
            self.name = name
        else:
            name, (self.start, size) = elf.lookup(spec)
            lo, hi = self.start, self.start + size
            # C name: a shared name gets its address
            self.name = name if len(elf.all.get(name, [])) == 1 else f"{name}_{self.start:x}"
        self.region = (lo, hi)
        # what FEX checks against the guest code: from the entry to the end of the region
        self.size = hi - self.start
        self.hashed = elf.read(self.start, self.size)
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        md.detail = True
        self.code = elf.read(lo, hi - lo)
        self.insns = list(md.disasm(self.code, lo))
        if sum(i.size for i in self.insns) != hi - lo:
            raise LiftError(f"{self.name}: decoding stopped early")
        self.at = {i.address: i for i in self.insns}
        self.analyse()

    def err(self, insn, msg):
        return LiftError(f"{self.name}+{insn.address - self.start:#x} ({insn.address:#x}: {insn.mnemonic} {insn.op_str}): {msg}")

    def inside(self, a):
        return self.region[0] <= a < self.region[1]

    def jump_table(self, insn):
        # notrack jmp [idx*8 + table], bounded by an earlier "cmp idx, n; ja default" in the same block; or, in a
        # position-independent program, the table holds 32-bit offsets from its own address:
        #   lea table(%rip), rT; movslq (rT, idx, 4), rJ; add rT, rJ; jmp *rJ
        # -> (index register, targets, None) or (None, targets, register jumped through)
        k = self.insns.index(insn)
        op = insn.operands[0]
        if op.type == X.X86_OP_REG:
            return self.relative_jump_table(insn, k)
        m = op.mem
        if m.base or not m.index or m.scale != 8:
            raise self.err(insn, "indirect jump that is not a jump table")
        idx = REGS[insn.reg_name(m.index)][0]
        n = self.table_bound(k, insn)
        table = m.disp & M64
        targets = [struct.unpack_from("<Q", self.elf.read(table + 8 * j, 8))[0] for j in range(n)]
        for t in targets:
            if not self.inside(t) or t not in self.at:
                raise self.err(insn, f"jump table entry {t:#x} outside the function")
        return idx, targets, None

    def table_bound(self, k, insn):
        # The nearest "cmp ..., n-1" that is followed by a ja (the compared value may be the memory word the index is
        # loaded from). An index outside the table at run time ends in aot_unreachable, so a bound found too small
        # fails loudly; table entries outside the function fail the translation.
        window = self.insns[max(0, k - 12):k]
        for j in range(len(window) - 2, -1, -1):
            prev = window[j]
            if prev.mnemonic == "cmp" and prev.operands[1].type == X.X86_OP_IMM and window[j + 1].mnemonic == "ja":
                return prev.operands[1].imm + 1
        raise self.err(insn, "jump table without bound")

    def relative_jump_table(self, insn, k):
        def reg(r):
            return REGS.get(insn.reg_name(r), (None,))[0] if r else None

        def writes(i, r):
            return any(o.type == X.X86_OP_REG and (o.access & capstone.CS_AC_WRITE) and reg(o.reg) == r for o in i.operands)

        # jmp rJ after "add rJ, rS": one of rJ and rS holds the table's address (lea), the other the entry read from
        # it (movsxd), searched backwards as long as nothing else writes them
        rj = reg(insn.operands[0].reg)
        add = movs = lea = None
        need = set()
        for prev in reversed(self.insns[max(0, k - 12):k]):
            ops = prev.operands
            if add is None:
                if prev.mnemonic == "add" and len(ops) == 2 and ops[1].type == X.X86_OP_REG and reg(ops[0].reg) == rj:
                    add = prev
                    need = {rj, reg(ops[1].reg)}
                elif writes(prev, rj):
                    break
            elif movs is None and prev.mnemonic == "movsxd" and ops[1].type == X.X86_OP_MEM and reg(ops[0].reg) in need:
                movs = prev
                need.discard(reg(ops[0].reg))
            elif lea is None and prev.mnemonic == "lea" and ops[1].type == X.X86_OP_MEM and prev.reg_name(ops[1].mem.base) == "rip" \
                    and reg(ops[0].reg) in need:
                lea = prev
                need.discard(reg(ops[0].reg))
            elif any(writes(prev, r) for r in need):
                break
            if movs and lea:
                break
        mm = movs.operands[1].mem if movs else None
        rt = reg(mm.base) if mm else None
        if not mm or not mm.index or mm.scale != 4 or mm.disp or rt == reg(movs.operands[0].reg) \
                or rt not in (reg(add.operands[0].reg), reg(add.operands[1].reg)):
            raise self.err(insn, "indirect jump that is not a jump table")
        if lea is None or reg(lea.operands[0].reg) != rt:
            # The table's address is often loaded once before a loop. The translated code branches on the target
            # the jump really takes and ends in aot_unreachable on one it does not know, so a table found through
            # the only rip-relative lea into that register is safe.
            leas = {(i.address + i.size + i.operands[1].mem.disp) & M64 for i in self.insns
                    if i.mnemonic == "lea" and i.operands[1].type == X.X86_OP_MEM
                    and i.reg_name(i.operands[1].mem.base) == "rip" and reg(i.operands[0].reg) == rt}
            if len(leas) != 1:
                raise self.err(insn, "indirect jump that is not a jump table")
            table = leas.pop()
        else:
            table = (lea.address + lea.size + lea.operands[1].mem.disp) & M64
        n = self.table_bound(k, insn)
        targets = [(table + struct.unpack_from("<i", self.elf.read(table + 4 * j, 4))[0]) & M64 for j in range(n)]
        for t in targets:
            if not self.inside(t) or t not in self.at:
                raise self.err(insn, f"jump table entry {t:#x} outside the function")
        return None, targets, rj

    def analyse(self):
        leaders = {self.start}
        self.tables = {}
        for k, insn in enumerate(self.insns):
            mn = insn.mnemonic.replace("notrack ", "").replace("bnd ", "")
            nxt = insn.address + insn.size
            if mn.startswith("j"):
                op = insn.operands[0]
                if op.type == X.X86_OP_IMM:
                    if self.inside(op.imm):
                        if op.imm not in self.at:
                            raise self.err(insn, "jump into an instruction")
                        leaders.add(op.imm)
                else:
                    self.tables[insn.address] = self.jump_table(insn)
                    leaders.update(self.tables[insn.address][1])
                if nxt in self.at:
                    leaders.add(nxt)
            elif mn == "ret" and nxt in self.at:
                leaders.add(nxt)
        self.leaders = leaders

        # rsp offset from the entry value before each reachable instruction
        index = {i.address: k for k, i in enumerate(self.insns)}
        delta = {}
        succ = {}
        work = [(self.start, 0)]
        while work:
            a, d = work.pop()
            k = index[a]
            while k < len(self.insns):
                insn = self.insns[k]
                if insn.address in delta:
                    if delta[insn.address] != d:
                        raise self.err(insn, f"rsp offset {d} meets {delta[insn.address]}")
                    break
                delta[insn.address] = d
                mn = insn.mnemonic
                ops = insn.operands
                if mn == "push":
                    d -= 8
                elif mn == "pop":
                    d += 8
                elif mn in ("sub", "add") and ops[0].type == X.X86_OP_REG and insn.reg_name(ops[0].reg) == "rsp":
                    if ops[1].type != X.X86_OP_IMM:
                        raise self.err(insn, "rsp changed by a register")
                    d += -ops[1].imm if mn == "sub" else ops[1].imm
                else:
                    for o in ops:
                        if o.type == X.X86_OP_REG and insn.reg_name(o.reg) in ("rsp", "esp", "sp") and (o.access & capstone.CS_AC_WRITE):
                            raise self.err(insn, "rsp written")
                fall = True
                targets = []
                if mn == "ret":
                    if d != 0:
                        raise self.err(insn, f"ret with rsp offset {d}")
                    fall = False
                elif mn.startswith(("j", "notrack j", "bnd j")):
                    op = ops[0]
                    if insn.address in self.tables:
                        targets = list(self.tables[insn.address][1])
                        fall = False
                    elif self.inside(op.imm):
                        targets = [op.imm]
                        fall = not mn.endswith("jmp")
                    else:
                        if not mn.endswith("jmp"):
                            raise self.err(insn, "conditional jump out of the function")
                        if d != 0:
                            raise self.err(insn, "tail jump with rsp offset")
                        fall = False
                elif mn in ("ud2", "hlt", "int3"):
                    fall = False
                work.extend((t, d) for t in targets)
                nxt = insn.address + insn.size
                succ[insn.address] = targets + ([nxt] if fall and nxt in self.at else [])
                if not fall:
                    break
                k += 1
        self.delta = delta
        self.succ = succ
        # Stack accesses: incoming arguments, frame slots, objects whose address is taken
        self.nstack = 0
        lea_offs = []
        self.frame_min = 0
        first_sub = None
        for insn in self.insns:
            if insn.address not in delta:
                continue
            d = delta[insn.address]
            if insn.mnemonic == "push":
                self.frame_min = min(self.frame_min, d - 8)
            if insn.mnemonic == "sub" and insn.operands[0].type == X.X86_OP_REG and insn.reg_name(insn.operands[0].reg) == "rsp" \
                    and first_sub is None:
                first_sub = d
            for o in insn.operands:
                if o.type != X.X86_OP_MEM or not o.mem.base or insn.reg_name(o.mem.base) != "rsp":
                    continue
                off = d + o.mem.disp
                if insn.mnemonic == "lea" or o.mem.index:
                    # an object reached through its address or an index: it stays on the guest stack
                    if off >= 0:
                        raise self.err(insn, "address of an incoming stack argument or the return address")
                    lea_offs.append(off)
                    continue
                if off >= 8:
                    self.nstack = max(self.nstack, off - 8 + o.size)
                elif off >= 0:
                    raise self.err(insn, "access to the return address")
                else:
                    self.frame_min = min(self.frame_min, off)
        self.esc = None
        if lea_offs:
            top = first_sub if first_sub is not None else min(delta.values())
            lo = min(lea_offs)
            if max(lea_offs) >= top:
                raise self.err(self.insns[0], "address taken inside the saved registers")
            self.esc = (lo, top)
        self.nstack = (self.nstack + 7) & ~7
        self.frame_size = (-self.frame_min + 15) & ~15

    def stack_kind(self, off):
        if off >= 8:
            return "arg"
        if self.esc and self.esc[0] <= off < self.esc[1]:
            return "esc"
        return "frame"


OWN = 1  # taint: an address into the function's own stack objects


def pbit(i):
    return 2 << i  # taint: derived from argument register i


class Lifter:
    def __init__(self, elf, funcs):
        self.elf = elf
        self.funcs = {f.name: f for f in funcs}
        self.by_start = {f.start: f for f in funcs}
        self.problems = []
        self.guest_stack_args = {}
        # Escape analysis, to a fixed point over the call graph: which argument registers of each function may leave
        # translated code when they hold addresses, and whether the addresses of a function's own stack objects may
        for f in funcs:
            f.param_escapes = set()
            f.own_escapes = False
        changed = True
        while changed:
            changed = False
            for f in funcs:
                e = self.escapes(f)
                own = bool(e & OWN)
                params = {i for i in range(6) if e & pbit(i)}
                if own != f.own_escapes or params != f.param_escapes:
                    f.own_escapes, f.param_escapes = own, params
                    changed = True
        for f in funcs:
            # stack objects stay in host memory unless their addresses can reach guest code or guest memory
            f.esc_host = bool(f.esc) and not f.own_escapes and not ESC_GUEST

    # --- escape analysis -----------------------------------------------------------------------------------------------
    def slot(self, f, insn, op, d):
        # a stack slot that is a host local (offset from the entry rsp), or None
        m = op.mem
        if not m.base or insn.reg_name(m.base) != "rsp" or m.index:
            return None
        off = d + m.disp
        return off if f.stack_kind(off) == "frame" else None

    def escapes(self, f):
        # Forward data flow over the function: a may-taint per register and per host stack slot, merged by union.
        # A tainted value escapes when it is stored anywhere but a host stack slot, passed to code that is not
        # translated (or to a translated function whose parameter escapes), or returned (own addresses only).
        entry = ({**{a: pbit(i) for i, a in enumerate(ARGS)}, "rsp": OWN}, {})
        state = {f.start: entry}
        work = [f.start]
        esc = 0
        while work:
            a = work.pop()
            regs, slots = dict(state[a][0]), dict(state[a][1])
            esc |= self.esc_step(f, f.at[a], regs, slots)
            for s in f.succ.get(a, []):
                old = state.get(s)
                if old is None:
                    state[s] = (regs, slots)
                    work.append(s)
                    continue
                nr, ns = dict(old[0]), dict(old[1])
                grew = False
                for src, dst in ((regs, nr), (slots, ns)):
                    for k, v in src.items():
                        if dst.get(k, 0) | v != dst.get(k, 0):
                            dst[k] = dst.get(k, 0) | v
                            grew = True
                if grew:
                    state[s] = (nr, ns)
                    work.append(s)
        return esc

    def esc_step(self, f, insn, regs, slots):
        d = f.delta[insn.address]
        mn = insn.mnemonic.replace("notrack ", "").replace("bnd ", "")
        ops = insn.operands

        def value(op):
            if op.type == X.X86_OP_REG:
                base, bits, hi = REGS[insn.reg_name(op.reg)]
                return regs.get(base, 0) if bits == 64 else 0
            if op.type == X.X86_OP_MEM:
                s = self.slot(f, insn, op, d)
                return slots.get(s, 0) if s is not None and op.size == 8 else 0
            return 0

        def setreg(op, m):
            base, bits, hi = REGS[insn.reg_name(op.reg)]
            if bits != 128:
                regs[base] = m if bits == 64 else 0

        def store(op, m):
            s = self.slot(f, insn, op, d)
            if s is None:
                return m
            for k in [k for k in slots if k < s + op.size and s < k + 8]:
                del slots[k]
            if op.size == 8:
                slots[s] = m
                return 0
            return m  # part of an address stored: treat as escaping

        if mn in ("nop", "endbr64") or mn.startswith("nop"):
            return 0
        if mn == "lea":
            mem = ops[1].mem
            m = 0
            for r in (mem.base, mem.index):
                if r:
                    base, bits, hi = REGS[insn.reg_name(r)] if insn.reg_name(r) in REGS else (None, 0, False)
                    m |= regs.get(base, 0) if bits == 64 else 0
            setreg(ops[0], m)
            return 0
        if mn == "push":
            for k in [k for k in slots if k < d and d - 8 < k + 8]:
                del slots[k]
            slots[d - 8] = value(ops[0])
            return 0
        if mn == "pop":
            setreg(ops[0], slots.get(d, 0))
            return 0
        if mn in ("mov", "movabs"):
            m = value(ops[1])
            if ops[0].type == X.X86_OP_REG:
                setreg(ops[0], m)
                return 0
            return store(ops[0], m)
        if mn.startswith("cmov"):
            setreg(ops[0], value(ops[0]) | value(ops[1]))
            return 0
        if mn == "xchg" and ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG:
            a, b = value(ops[0]), value(ops[1])
            setreg(ops[0], b)
            setreg(ops[1], a)
            return 0
        if mn == "ret":
            return regs.get("rax", 0) & OWN
        if mn == "call" or mn == "jmp" and ops[0].type == X.X86_OP_IMM and not f.inside(ops[0].imm):
            args = [regs.get(a, 0) for a in ARGS]
            callee = self.by_start.get(ops[0].imm) if ops[0].type == X.X86_OP_IMM else None
            e = 0
            if callee:
                for i, m in enumerate(args):
                    if i in callee.param_escapes:
                        e |= m
                for k in range(0, callee.nstack, 8):
                    e |= slots.get(d + k, 0)
            else:
                # guest code (or an indirect call that may reach it): every argument, and anything in the outgoing area
                for m in args:
                    e |= m
                for k, m in slots.items():
                    if k >= d:
                        e |= m
            if mn == "call":
                regs["rax"] = 0
                for m in args:
                    regs["rax"] |= m  # it may return one of its arguments
            else:
                e |= regs.get("rax", 0) & OWN
            return e
        if mn.startswith("j"):
            return 0
        # Anything else: what it writes is derived from everything it reads
        rd = 0
        for o in ops:
            if o.access & capstone.CS_AC_READ:
                rd |= value(o)
        e = 0
        explicit = set()
        for o in ops:
            if o.access & capstone.CS_AC_WRITE:
                if o.type == X.X86_OP_REG:
                    explicit.add(REGS[insn.reg_name(o.reg)][0])
                    setreg(o, rd)
                elif o.type == X.X86_OP_MEM:
                    e |= store(o, rd)
        for r in insn.regs_access()[1]:
            name = insn.reg_name(r)
            if name in REGS and REGS[name][0] not in explicit and REGS[name][1] != 128 and REGS[name][0] != "rsp":
                regs[REGS[name][0]] = 0
        return e

    # --- per-function emission ---------------------------------------------------------------------------------------
    def lift(self, f, ordered):
        # the plain variant (f_) or the ordered one (o_): guest memory through the ordered view, acquire loads and
        # release stores; a function that met shared memory runs ordered from its next call on (aot_mode)
        self.f = f
        self.ordered = ordered
        self.pre = "o_" if ordered else "f_"
        self.out = []
        self.temps = []
        self.fd = None  # flags of the current block: (kind, bits, values...)
        for insn in f.insns:
            if insn.address in f.leaders:
                self.fd = None
                self.out.append(f"L_{insn.address:x}: ;")
            if insn.address not in f.delta:
                # never reached from the entry (padding, code after calls that do not return)
                if insn.mnemonic not in ("nop", "int3", "ud2", "hlt") and not insn.mnemonic.startswith(("nop", "data16")):
                    self.out.append(f"    aot_unreachable({insn.address:#x}ULL);")
                continue
            self.insn = insn
            self.d = f.delta[insn.address]
            try:
                self.emit_insn(insn)
            except LiftError as e:
                # collected: all problems of a run are reported together
                self.problems.append(str(e))
                self.e(f"aot_unreachable({insn.address:#x}ULL);")
        params = ", ".join(f"uint64_t {a}" for a in ARGS)
        head = [f"static uint64_t {self.pre}{f.name}(struct aot_ctx *c, uint8_t *V, uint64_t gsp, uint8_t *A, {params})", "{"]
        decl = []
        if ordered:
            decl.append("    uint8_t *O = c->oview;")
        else:
            decl.append(f"    if (__builtin_expect(aot_mode[{f.index}], 0))")
            decl.append(f"        return o_{f.name}(c, V, gsp, A, {self.call_args()});")
            if f.unit:
                decl.append("    uint8_t *O = c->oview;")
        if f.unit:
            # a string function as one unit: ordered against everything before it and after it, its own accesses in
            # any order (the C library leaves their order unspecified), through the ordered view so that shared
            # pages do not fault; without views and without ordering (O == V, the plain variant) no barriers
            decl.append("    const bool unit_fence = O != V" + (" || 1" if ordered else "") + ";")
            decl.append("    if (unit_fence) __asm__ volatile(\"dmb ish\" ::: \"memory\");")
        locs = [r for r in GPRS if r not in ARGS]
        decl.append("    uint64_t " + ", ".join(f"{r} = 0" for r in locs) + ";")
        decl.append("    u128 " + ", ".join(f"x{i} = {{0, 0}}" for i in range(16)) + ";")
        decl.append("    u128 " + ", ".join(f"y{i} = {{0, 0}}" for i in range(16)) + "; // upper halves of ymm")
        decl.append("    bool cf = 0, zf = 0, sf = 0, of = 0;")
        if f.frame_size:
            decl.append(f"    uint8_t F[{f.frame_size}] __attribute__((aligned(16)));")
        if f.esc_host:
            decl.append(f"    uint8_t E[{(f.esc[1] - f.esc[0] + 15) & ~15}] __attribute__((aligned(16)));")
        decl.append("    (void)c; (void)V; (void)gsp; (void)A;")
        for ty, n in self.temps:
            decl.append(f"    {ty} {n};")
        if f.start != f.region[0]:
            decl.append(f"    goto L_{f.start:x}; // the entry lies inside the region")
        return head + decl + self.out + ["}"]

    def e(self, s):
        self.out.append("    " + s)

    def err(self, msg):
        return self.f.err(self.insn, msg)

    def tmp(self, bits, expr):
        n = f"t{len(self.temps)}"
        self.temps.append((T[bits], n))
        self.e(f"{n} = {expr};")
        return n

    # --- operands ------------------------------------------------------------------------------------------------------
    def reg(self, op):
        return REGS[self.insn.reg_name(op.reg)]

    def rreg(self, name, bits=None):
        base, b, hi = REGS[name]
        if hi:
            return f"((uint8_t)({base} >> 8))"
        if b in (64, 128):
            return base
        return f"(({T[b]}){base})"

    def wreg(self, op, value):
        base, b, hi = self.reg(op)
        if b == 128:
            self.e(f"{base} = {value};")
        elif hi:
            self.e(f"{base} = ({base} & ~0xff00ULL) | ((uint64_t)(uint8_t)({value}) << 8);")
        elif b == 64:
            self.e(f"{base} = (uint64_t)({value});")
        elif b == 32:
            self.e(f"{base} = (uint32_t)({value});")
        else:
            self.e(f"{base} = ({base} & ~{mask(b):#x}ULL) | ({T[b]})({value});")

    def address(self, op):
        # -> ("const", int) | ("stack", offset) | ("dyn", C expression, read-only table)
        m = op.mem
        if m.segment and self.insn.reg_name(m.segment) not in ("cs", "ds", "ss", "es"):
            raise self.err("segment override")
        base = self.insn.reg_name(m.base) if m.base else None
        index = self.insn.reg_name(m.index) if m.index else None
        if base == "rip":
            return ("const", (self.insn.address + self.insn.size + m.disp) & M64)
        if base and REGS[base][1] != 64 or index and REGS[index][1] != 64:
            raise self.err("32-bit address")
        if base == "rsp":
            return ("stack", self.d + m.disp, index, m.scale)
        if not base and not index:
            return ("const", m.disp & M64)
        parts = []
        if base:
            parts.append(base)
        if index:
            parts.append(f"{index} * {m.scale}" if m.scale != 1 else index)
        if m.disp:
            parts.append(f"{m.disp & M64:#x}ULL")
        # a table in a read-only segment, indexed by a register (base or index): immutable data. Not in a
        # position-independent program: there a displacement is never an absolute address
        ro = not self.elf.pie and self.elf.readonly(m.disp & M64) and (m.disp & M64) >= self.elf.segs[0][0]
        return ("dyn", "(" + " + ".join(parts) + ")", ro)

    def esc_base(self):
        # where the stack objects whose address is taken live: on the guest stack, or in a host array that their
        # (guest) addresses reach through the view, V + address; the latter only when the escape analysis shows that
        # these addresses stay in translated code and out of memory
        if self.f.esc_host:
            return f"((uint64_t)(uintptr_t)E - (uint64_t)(uintptr_t)V - {self.f.esc[0] & M64:#x}ULL)"
        return "gsp"

    def gconst(self, v):
        # an address of the program: as it is, or for a position-independent program relative to where it was loaded
        return f"(aot_base + {v:#x}ULL)" if self.elf.pie else f"{v:#x}ULL"

    def lea_value(self, op):
        a = self.address(op)
        if a[0] == "const":
            return self.gconst(a[1])
        if a[0] == "stack":
            _, off, index, scale = a
            s = f"({self.esc_base()} + {off & M64:#x}ULL"
            if index:
                s += f" + {index} * {scale}"
            return s + ")"
        return a[1]

    def guest_addr(self, a):
        # a resolved address -> (C address expression, accessor prefix): g volatile guest, r read-only guest, h host
        if a[0] == "const":
            return (self.gconst(a[1]), "r" if self.elf.readonly(a[1]) else "g")
        if a[0] == "dyn":
            return (a[1], "r" if a[2] else "g")
        _, off, index, scale = a
        kind = self.f.stack_kind(off)
        if index:
            if kind != "esc":
                raise self.err("indexed stack access outside the guest stack objects")
            return (f"({self.esc_base()} + {off & M64:#x}ULL + {index} * {scale})", "s")
        if kind == "arg":
            return (f"A + {off - 8}", "h")
        if kind == "esc":
            # the thread's own stack for translated code (or a host array): private, plain in both variants
            return (f"{self.esc_base()} + {off & M64:#x}ULL", "s")
        return (f"F + {off - self.f.frame_min}", "h")

    def load(self, op, bits=None):
        bits = bits or op.size * 8
        a = self.address(op)
        if a[0] == "const" and self.elf.readonly(a[1], bits // 8) and not self.elf.relocated(a[1], bits // 8):
            v = int.from_bytes(self.elf.read(a[1], bits // 8), "little")
            if bits == 128:
                return f"((u128){{{v & M64:#x}ULL, {v >> 64:#x}ULL}})"
            return f"(({T[bits]}){v:#x}ULL)"
        expr, kind = self.guest_addr(a)
        return self.ld(kind, bits, expr)

    # accessors by kind: h host memory, r read-only guest data, s the thread's own guest stack, g guest memory (plain
    # view, or the ordered view in the ordered variant)
    def stack_view(self):
        # the thread's own stack for translated code is private, but under the protocol's fallback to full ordering
        # every page is shared and reachable through the ordered view only: the ordered variant goes there (plain
        # accesses, nobody else uses that stack); stack objects in host memory are reached through V in both variants
        return "O" if self.ordered and not self.f.esc_host else "V"

    def ld(self, kind, bits, expr):
        if kind == "h":
            return f"hld{bits}({expr})"
        if kind == "r":
            return f"rld{bits}(V, {expr})"
        if kind == "g" and self.f.unit:
            return f"gld{bits}(O, {expr})"
        if kind == "g" and self.ordered:
            return f"old{bits}(O, V, {expr})"
        if kind == "s":
            return f"gld{bits}({self.stack_view()}, {expr})"
        return f"gld{bits}(V, {expr})"

    def st(self, kind, bits, expr, value):
        if kind == "h":
            return f"hst{bits}({expr}, {value});"
        if kind == "g" and self.f.unit:
            return f"gst{bits}(O, {expr}, {value});"
        if kind == "g" and self.ordered:
            return f"ost{bits}(O, V, {expr}, {value});"
        if kind == "s":
            return f"gst{bits}({self.stack_view()}, {expr}, {value});"
        return f"gst{bits}(V, {expr}, {value});"

    def store(self, op, value, bits=None):
        bits = bits or op.size * 8
        a = self.address(op)
        expr, kind = self.guest_addr(a)
        self.e(self.st(kind, bits, expr, value))

    def src(self, op, bits):
        if op.type == X.X86_OP_REG:
            base, b, hi = self.reg(op)
            if b == bits or b == 128:
                return self.rreg(self.insn.reg_name(op.reg))
            return f"(({T[bits]}){self.rreg(self.insn.reg_name(op.reg))})"
        if op.type == X.X86_OP_IMM:
            return f"(({T[bits]}){op.imm & mask(bits):#x}ULL)"
        return self.load(op, bits)

    def dst(self, op, value, bits):
        if op.type == X.X86_OP_REG:
            self.wreg(op, value)
        else:
            self.store(op, value, bits)

    def rmw(self, op, bits):
        # read a destination operand once (its address computed once): returns (value temp, writer)
        if op.type == X.X86_OP_REG:
            v = self.tmp(bits, self.src(op, bits))
            return v, lambda val: self.wreg(op, val)
        a = self.address(op)
        expr, kind = self.guest_addr(a)
        if kind != "h" and a[0] == "dyn":
            at = self.tmp(64, expr)
            expr = at
        if kind == "r":
            raise self.err("write to read-only data")
        v = self.tmp(bits, self.ld(kind, bits, expr))
        return v, lambda val: self.e(self.st(kind, bits, expr, val))

    # --- flags ---------------------------------------------------------------------------------------------------------
    def flags_zs(self, r, bits):
        self.e(f"zf = {r} == 0; sf = ({S[bits]}){r} < 0;")

    def flags_sub(self, a, b, r, bits):
        self.e(f"cf = {a} < {b}; of = ((({a} ^ {b}) & ({a} ^ {r})) >> {bits - 1}) & 1;")
        self.flags_zs(r, bits)
        self.fd = ("sub", bits, a, b, r)

    def flags_add(self, a, b, r, bits):
        self.e(f"cf = {r} < {a}; of = (((~({a} ^ {b})) & ({a} ^ {r})) >> {bits - 1}) & 1;")
        self.flags_zs(r, bits)
        self.fd = ("add", bits, a, b, r)

    def flags_logic(self, r, bits):
        self.e("cf = 0; of = 0;")
        self.flags_zs(r, bits)
        self.fd = ("logic", bits, r)

    def cond(self, cc):
        fd = self.fd
        if fd:
            kind, bits = fd[0], fd[1]
            s = S.get(bits)
            if kind == "sub":
                a, b, r = fd[2:]
                m = {"e": f"{a} == {b}", "ne": f"{a} != {b}", "b": f"{a} < {b}", "ae": f"{a} >= {b}", "be": f"{a} <= {b}",
                     "a": f"{a} > {b}", "l": f"({s}){a} < ({s}){b}", "ge": f"({s}){a} >= ({s}){b}",
                     "le": f"({s}){a} <= ({s}){b}", "g": f"({s}){a} > ({s}){b}", "s": f"({s}){r} < 0", "ns": f"({s}){r} >= 0"}
                if cc in m:
                    return m[cc]
            elif kind == "logic":
                r = fd[2]
                m = {"e": f"{r} == 0", "ne": f"{r} != 0", "s": f"({s}){r} < 0", "ns": f"({s}){r} >= 0", "l": f"({s}){r} < 0",
                     "ge": f"({s}){r} >= 0", "le": f"({s}){r} <= 0", "g": f"({s}){r} > 0", "b": "0", "ae": "1",
                     "be": f"{r} == 0", "a": f"{r} != 0", "o": "0", "no": "1"}
                if cc in m:
                    return m[cc]
            elif kind == "add":
                a, b, r = fd[2:]
                m = {"e": f"{r} == 0", "ne": f"{r} != 0", "b": f"{r} < {a}", "ae": f"{r} >= {a}", "s": f"({s}){r} < 0",
                     "ns": f"({s}){r} >= 0"}
                if cc in m:
                    return m[cc]
            elif kind == "zs":
                r = fd[2]
                m = {"e": f"{r} == 0", "ne": f"{r} != 0", "s": f"({s}){r} < 0", "ns": f"({s}){r} >= 0"}
                if cc in m:
                    return m[cc]
        m = {"o": "of", "no": "!of", "b": "cf", "ae": "!cf", "e": "zf", "ne": "!zf", "be": "(cf | zf)", "a": "(!cf & !zf)",
             "s": "sf", "ns": "!sf", "l": "(sf != of)", "ge": "(sf == of)", "le": "(zf | (sf != of))", "g": "(!zf & (sf == of))"}
        if cc not in m:
            raise self.err(f"condition {cc}")
        return m[cc]

    # --- calls ---------------------------------------------------------------------------------------------------------
    def call_args(self):
        return ", ".join(ARGS)

    def callee_argp(self, callee, off):
        if not callee.nstack:
            return "0"
        kinds = {self.f.stack_kind(off + k) for k in range(0, callee.nstack, 8)}
        if len(kinds) != 1:
            raise self.err("outgoing stack arguments split between host and guest stack")
        kind = kinds.pop()
        if kind == "esc":
            return f"(V + gsp + {off & M64:#x}ULL)"
        if kind == "frame":
            return f"(F + {off - self.f.frame_min})"
        raise self.err("outgoing stack arguments in the incoming argument area")

    def guest_nstack(self, target):
        # stack argument bytes a function that is not translated reads (decoded only for that); 0 if it has no
        # symbol (PLT entries: memcpy and friends take register arguments)
        if target not in self.guest_stack_args:
            n = 0
            for name, entries in self.elf.all.items():
                if any(a == target for a, s in entries):
                    try:
                        n = Function(self.elf, f"{name}@{target:x}").nstack
                    except LiftError as e:
                        raise self.err(f"cannot tell the stack arguments of {name}: {e}")
                    break
            self.guest_stack_args[target] = n
        return self.guest_stack_args[target]

    def plt_got(self, target):
        # A PLT entry ([endbr64;] [bnd] jmp *GOT(%rip)): the GOT slot it jumps through, or None
        try:
            b = self.elf.read(target, 11)
        except LiftError:
            return None
        at = 4 if b[:4] == b"\xf3\x0f\x1e\xfa" else 0
        if b[at] == 0xF2:
            at += 1
        if b[at:at + 2] != b"\xff\x25":
            return None
        disp = struct.unpack_from("<i", b, at + 2)[0]
        return target + at + 6 + disp

    def direct_call(self, target, gsp_expr, argp_off, tail):
        callee = self.by_start.get(target)
        if callee:
            argp = "A" if tail else self.callee_argp(callee, argp_off)
            return f"{self.pre}{callee.name}(c, V, {gsp_expr}, {argp}, {self.call_args()})"
        got = self.plt_got(target)
        if got is not None:
            # through the PLT (glibc's string functions, chosen at start-up by IRELATIVE relocations): the GOT slot,
            # written before any translated code runs, names the target; a translated one is called directly
            return f"aot_dispatch_{self.pre[0]}(c, V, rld64(V, {self.gconst(got)}), {gsp_expr}, {self.call_args()})"
        n = self.guest_nstack(target)
        if n:
            if tail:
                raise self.err("tail call with stack arguments into guest code")
            # the outgoing stack arguments go where the x86 code has them, on the guest stack above the callee's
            # return address slot (gsp + offset: the thread's own stack for translated code)
            for k in range(0, n, 8):
                off = argp_off + k
                kind = self.f.stack_kind(off)
                if kind == "frame":
                    view = "O" if self.ordered else "V"
                    self.e(f"gst64({view}, gsp + {off & M64:#x}ULL, hld64(F + {off - self.f.frame_min}));")
                elif kind != "esc" or self.f.esc_host:
                    raise self.err("outgoing stack arguments for guest code outside the frame")
        return f"aot_guest_call(c, {self.gconst(target)}, {gsp_expr}, {self.call_args()})"

    # --- instructions --------------------------------------------------------------------------------------------------
    def emit_insn(self, insn):
        mn = insn.mnemonic
        ops = insn.operands
        if mn.startswith("notrack "):
            mn = mn[len("notrack "):]
        if mn.startswith("bnd "):
            mn = mn[4:]
        if mn in ("nop", "endbr64") or mn.startswith("nop"):
            return
        if mn.startswith("lock "):
            return self.locked(insn, ops, mn[5:])
        if mn.startswith("rep stos"):
            return self.rep_stos(insn, ops)
        if mn == "rep movsb":
            return self.i_rep_movsb(insn, ops)
        h = getattr(self, "i_" + mn, None)
        if h:
            return h(insn, ops)
        if mn.startswith("j"):
            return self.i_jcc(insn, ops)
        if mn.startswith("cmov"):
            return self.i_cmov(insn, ops)
        if mn.startswith("set"):
            return self.i_setcc(insn, ops)
        raise self.err("instruction not supported")

    def bits0(self, ops):
        return ops[0].size * 8

    def i_mov(self, insn, ops):
        bits = self.bits0(ops)
        self.dst(ops[0], self.src(ops[1], bits), bits)

    i_movabs = i_mov

    def i_movzx(self, insn, ops):
        sb = ops[1].size * 8
        self.dst(ops[0], self.src(ops[1], sb), self.bits0(ops))

    def i_movsx(self, insn, ops):
        sb = ops[1].size * 8
        db = self.bits0(ops)
        self.dst(ops[0], f"({T[db]})({S[db]})({S[sb]}){self.src(ops[1], sb)}", db)

    i_movsxd = i_movsx

    def i_cdqe(self, insn, ops):
        self.e("rax = (uint64_t)(int64_t)(int32_t)rax;")

    def i_cqo(self, insn, ops):
        self.e("rdx = (uint64_t)((int64_t)rax >> 63);")

    def i_cdq(self, insn, ops):
        self.e("rdx = (uint32_t)((int32_t)rax >> 31);")

    def i_lea(self, insn, ops):
        self.wreg(ops[0], self.lea_value(ops[1]))

    def i_push(self, insn, ops):
        v = self.src(ops[0], 64)
        off = self.d - 8
        kind = self.f.stack_kind(off)
        if kind != "frame":
            raise self.err("push into the guest stack")
        self.e(f"hst64(F + {off - self.f.frame_min}, {v});")

    def i_pop(self, insn, ops):
        off = self.d
        if self.f.stack_kind(off) != "frame":
            raise self.err("pop from the guest stack")
        self.wreg(ops[0], f"hld64(F + {off - self.f.frame_min})")

    def binop(self, ops, fn, flags):
        bits = self.bits0(ops)
        if ops[0].type == X.X86_OP_REG and insn_is_rsp(self.insn, ops[0]):
            return  # stack pointer arithmetic: tracked statically
        a, write = self.rmw(ops[0], bits)
        b = self.tmp(bits, self.src(ops[1], bits))
        r = self.tmp(bits, fn(a, b))
        write(r)
        flags(a, b, r, bits)

    def i_add(self, insn, ops):
        self.binop(ops, lambda a, b: f"{a} + {b}", self.flags_add)

    def i_sub(self, insn, ops):
        if ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            bits = self.bits0(ops)
            self.wreg(ops[0], "0")
            z = self.tmp(bits, "0")
            self.flags_sub(z, z, z, bits)
            return
        self.binop(ops, lambda a, b: f"{a} - {b}", self.flags_sub)

    def i_cmp(self, insn, ops):
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[0], bits))
        b = self.tmp(bits, self.src(ops[1], bits))
        r = self.tmp(bits, f"{a} - {b}")
        self.flags_sub(a, b, r, bits)

    def logic(self, ops, op):
        bits = self.bits0(ops)
        if ops[0].type == X.X86_OP_REG and insn_is_rsp(self.insn, ops[0]):
            raise self.err("logic on rsp")
        a, write = self.rmw(ops[0], bits)
        b = self.src(ops[1], bits)
        r = self.tmp(bits, f"{a} {op} {b}")
        write(r)
        self.flags_logic(r, bits)

    def i_and(self, insn, ops):
        self.logic(ops, "&")

    def i_or(self, insn, ops):
        self.logic(ops, "|")

    def i_xor(self, insn, ops):
        if ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            bits = self.bits0(ops)
            self.wreg(ops[0], "0")
            self.flags_logic(self.tmp(bits, "0"), bits)
            return
        self.logic(ops, "^")

    def i_test(self, insn, ops):
        bits = self.bits0(ops)
        a = self.src(ops[0], bits)
        b = self.src(ops[1], bits)
        r = self.tmp(bits, f"{a} & {b}")
        self.flags_logic(r, bits)

    def i_not(self, insn, ops):
        bits = self.bits0(ops)
        a, write = self.rmw(ops[0], bits)
        write(f"~{a}")

    def i_neg(self, insn, ops):
        bits = self.bits0(ops)
        a, write = self.rmw(ops[0], bits)
        z = self.tmp(bits, "0")
        r = self.tmp(bits, f"{z} - {a}")
        write(r)
        self.flags_sub(z, a, r, bits)

    def incdec(self, ops, op, edge):
        bits = self.bits0(ops)
        a, write = self.rmw(ops[0], bits)
        r = self.tmp(bits, f"{a} {op} 1")
        write(r)
        self.e(f"of = {r} == ({T[bits]}){edge:#x}ULL;")
        self.flags_zs(r, bits)
        self.fd = ("zs", bits, r)

    def i_inc(self, insn, ops):
        self.incdec(ops, "+", 1 << (self.bits0(ops) - 1))

    def i_dec(self, insn, ops):
        self.incdec(ops, "-", (1 << (self.bits0(ops) - 1)) - 1)

    def carry_op(self, ops, sub):
        bits = self.bits0(ops)
        a, write = self.rmw(ops[0], bits)
        b = self.tmp(bits, self.src(ops[1], bits))
        c = self.tmp(bits, "cf")
        if sub:
            r = self.tmp(bits, f"{a} - {b} - {c}")
            self.e(f"cf = ({a} < {b}) | (({T[bits]})({a} - {b}) < {c}); of = ((({a} ^ {b}) & ({a} ^ {r})) >> {bits - 1}) & 1;")
        else:
            r = self.tmp(bits, f"{a} + {b} + {c}")
            self.e(f"cf = ({r} < {a}) | (({r} == {a}) & ({c} != 0)); of = (((~({a} ^ {b})) & ({a} ^ {r})) >> {bits - 1}) & 1;")
        write(r)
        self.flags_zs(r, bits)
        self.fd = ("zs", bits, r)

    def i_sbb(self, insn, ops):
        self.carry_op(ops, True)

    def i_adc(self, insn, ops):
        self.carry_op(ops, False)

    def shift(self, ops, kind):
        bits = self.bits0(ops)
        cmask = 63 if bits == 64 else 31
        a, write = self.rmw(ops[0], bits)
        if len(ops) == 1:
            cnt = 1
        elif ops[1].type == X.X86_OP_IMM:
            cnt = ops[1].imm & cmask
        else:
            cnt = None
        if cnt == 0:
            return
        c = str(cnt) if cnt is not None else self.tmp(8, f"(uint8_t)rcx & {cmask}")
        if kind == "shl":
            r = self.tmp(bits, f"({T[bits]})({a} << {c})")
            cf = f"({a} >> ({bits} - {c})) & 1" if cnt is None or cnt <= bits else "0"
            of = f"(({r} >> {bits - 1}) ^ ({cf})) & 1"
        elif kind == "shr":
            r = self.tmp(bits, f"({T[bits]})({a} >> {c})")
            cf = f"({a} >> ({c} - 1)) & 1"
            of = f"({a} >> {bits - 1}) & 1"
        elif kind == "sar":
            r = self.tmp(bits, f"({T[bits]})(({S[bits]}){a} >> {c})")
            cf = f"(({S[bits]}){a} >> ({c} - 1)) & 1"
            of = "0"
        elif kind in ("rol", "ror"):
            if cnt is None:
                raise self.err("rotate by register")
            n = cnt % bits
            if n == 0:
                return
            if kind == "rol":
                r = self.tmp(bits, f"({T[bits]})(({a} << {n}) | ({a} >> {bits - n}))")
                cf = f"{r} & 1"
                of = f"(({r} >> {bits - 1}) ^ {r}) & 1"
            else:
                r = self.tmp(bits, f"({T[bits]})(({a} >> {n}) | ({a} << {bits - n}))")
                cf = f"({r} >> {bits - 1}) & 1"
                of = f"(({r} >> {bits - 1}) ^ ({r} >> {bits - 2})) & 1"
            write(r)
            self.e(f"cf = {cf}; of = {of};")
            self.fd = None
            return
        if cnt is None:
            self.e(f"if ({c}) {{")
            write(r)
            self.e(f"    cf = {cf}; of = {of}; zf = {r} == 0; sf = ({S[bits]}){r} < 0;")
            self.e("}")
            self.fd = None
        else:
            write(r)
            self.e(f"cf = {cf}; of = {of};")
            self.flags_zs(r, bits)
            self.fd = ("zs", bits, r)

    def i_shl(self, insn, ops):
        self.shift(ops, "shl")

    i_sal = i_shl

    def i_shr(self, insn, ops):
        self.shift(ops, "shr")

    def i_sar(self, insn, ops):
        self.shift(ops, "sar")

    def i_rol(self, insn, ops):
        self.shift(ops, "rol")

    def i_ror(self, insn, ops):
        self.shift(ops, "ror")

    def i_imul(self, insn, ops):
        bits = self.bits0(ops)
        if len(ops) == 1:
            raise self.err("one-operand imul")
        if len(ops) == 2:
            a = self.tmp(bits, self.src(ops[0], bits))
            b = self.tmp(bits, self.src(ops[1], bits))
        else:
            a = self.tmp(bits, self.src(ops[1], bits))
            b = self.tmp(bits, self.src(ops[2], bits))
        r = self.tmp(bits, f"({T[bits]})({a} * {b})")
        self.wreg(ops[0], r)
        if bits == 64:
            self.e(f"{{ int64_t p_; cf = of = __builtin_mul_overflow((int64_t){a}, (int64_t){b}, &p_); }}")
        else:
            self.e(f"cf = of = (int64_t)({S[bits]}){r} != (int64_t)({S[bits]}){a} * (int64_t)({S[bits]}){b};")
        self.fd = None

    def i_tzcnt(self, insn, ops):
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[1], bits))
        fn = "__builtin_ctzll" if bits == 64 else "__builtin_ctz"
        r = self.tmp(bits, f"{a} ? ({T[bits]}){fn}({a}) : {bits}")
        self.wreg(ops[0], r)
        self.e(f"cf = {a} == 0; zf = {r} == 0;")
        self.fd = None

    def i_bsr(self, insn, ops):
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[1], bits))
        fn = "__builtin_clzll" if bits == 64 else "__builtin_clz"
        self.e(f"if ({a}) {{")
        self.wreg(ops[0], f"{bits - 1} - {fn}({a})")
        self.e("}")
        self.e(f"zf = {a} == 0;")
        self.fd = None

    def i_bsf(self, insn, ops):
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[1], bits))
        fn = "__builtin_ctzll" if bits == 64 else "__builtin_ctz"
        self.e(f"if ({a}) {{")
        self.wreg(ops[0], f"{fn}({a})")
        self.e("}")
        self.e(f"zf = {a} == 0;")
        self.fd = None

    def i_cmov(self, insn, ops):
        bits = self.bits0(ops)
        c = self.cond(cc_of(insn.mnemonic, "cmov"))
        s = self.tmp(bits, self.src(ops[1], bits))
        self.wreg(ops[0], f"({c}) ? {s} : {self.src(ops[0], bits)}")

    def i_setcc(self, insn, ops):
        c = self.cond(cc_of(insn.mnemonic, "set"))
        self.dst(ops[0], f"(uint8_t)({c})", 8)

    def i_jcc(self, insn, ops):
        mn = insn.mnemonic
        if mn.startswith("notrack "):
            mn = mn[len("notrack "):]
        if mn == "jmp":
            return self.i_jmp(insn, ops)
        c = self.cond(cc_of(mn, "j"))
        t = ops[0].imm
        if not self.f.inside(t):
            raise self.err("conditional jump out of the function")
        self.e(f"if ({c}) goto L_{t:x};")

    def i_jmp(self, insn, ops):
        op = ops[0]
        if insn.address in self.f.tables:
            idx, targets, through = self.f.tables[insn.address]
            if idx:
                self.e(f"switch ({idx}) {{")
                for j, t in enumerate(targets):
                    self.e(f"case {j}: goto L_{t:x};")
            else:
                # a table of offsets: the register holds the target itself (relative to aot_base when relocated)
                self.e(f"switch ({through} - aot_base) {{" if self.f.elf.pie else f"switch ({through}) {{")
                for t in sorted(set(targets)):
                    self.e(f"case {t:#x}ULL: goto L_{t:x};")
            self.e(f"default: aot_unreachable({insn.address:#x}ULL);")
            self.e("}")
            return
        if op.type != X.X86_OP_IMM:
            raise self.err("indirect jump")
        if self.f.inside(op.imm):
            self.e(f"goto L_{op.imm:x};")
            return
        self.e(f"return {self.direct_call(op.imm, 'gsp', 0, True)};")

    def i_call(self, insn, ops):
        op = ops[0]
        gsp_expr = f"gsp + {(self.d - 8) & M64:#x}ULL"
        if op.type == X.X86_OP_IMM:
            self.e(f"rax = {self.direct_call(op.imm, gsp_expr, self.d, False)};")
        else:
            t = self.tmp(64, self.src(op, 64))
            self.e(f"rax = aot_dispatch_{self.pre[0]}(c, V, {t}, {gsp_expr}, {self.call_args()});")
        self.fd = None

    def i_ret(self, insn, ops):
        if ops:
            raise self.err("ret with operand")
        if self.f.unit:
            self.e("if (unit_fence) __asm__ volatile(\"dmb ish\" ::: \"memory\");")
        self.e("return rax;")

    # --- atomics and fences ----------------------------------------------------------------------------------------
    # Atomics go to the ordered view: read/write there on shared pages, and a private page of another thread moves
    # through an ordinary transition of the page protocol. They are sequentially consistent, as locked x86 operations.
    def atomic_ptr(self, op, bits):
        a = self.address(op)
        if a[0] == "stack":
            if self.f.stack_kind(a[1]) != "esc" or self.f.esc_host:
                raise self.err("atomic on a host stack slot")
            expr = f"({self.esc_base()} + {a[1] & M64:#x}ULL)"
        elif a[0] == "const":
            expr = self.gconst(a[1])
        else:
            expr = a[1]
        p = self.tmp(64, f"(uint64_t)(uintptr_t)(c->oview + {expr})")
        return f"(({T[bits]} *)(uintptr_t){p})"

    def i_xchg(self, insn, ops):
        if ops[0].type == X.X86_OP_MEM or ops[1].type == X.X86_OP_MEM:
            m, r = (ops[0], ops[1]) if ops[0].type == X.X86_OP_MEM else (ops[1], ops[0])
            bits = m.size * 8
            p = self.atomic_ptr(m, bits)
            old = self.tmp(bits, f"__atomic_exchange_n({p}, {self.src(r, bits)}, __ATOMIC_SEQ_CST)")
            self.wreg(r, old)
            return
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[0], bits))
        b = self.tmp(bits, self.src(ops[1], bits))
        self.wreg(ops[0], b)
        self.wreg(ops[1], a)

    def locked(self, insn, ops, mn):
        bits = self.bits0(ops)
        if ops[0].type != X.X86_OP_MEM:
            raise self.err("lock without a memory destination")
        p = self.atomic_ptr(ops[0], bits)
        if mn == "xadd":
            b = self.tmp(bits, self.src(ops[1], bits))
            old = self.tmp(bits, f"__atomic_fetch_add({p}, {b}, __ATOMIC_SEQ_CST)")
            r = self.tmp(bits, f"{old} + {b}")
            self.wreg(ops[1], old)
            self.flags_add(old, b, r, bits)
        elif mn == "cmpxchg":
            acc = {8: "al", 16: "ax", 32: "eax", 64: "rax"}[bits]
            exp = self.tmp(bits, self.rreg(acc))
            want = self.tmp(bits, exp)
            new = self.tmp(bits, self.src(ops[1], bits))
            ok = self.tmp(8, f"__atomic_compare_exchange_n({p}, &{exp}, {new}, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)")
            # exp now holds the old memory value; the accumulator is written only when the comparison failed
            self.e(f"if (!{ok}) {{")
            if bits == 32:
                self.e(f"    rax = (uint32_t){exp};")
            elif bits == 64:
                self.e(f"    rax = {exp};")
            else:
                self.e(f"    rax = (rax & ~{mask(bits):#x}ULL) | {exp};")
            self.e("}")
            r = self.tmp(bits, f"{want} - {exp}")
            self.flags_sub(want, exp, r, bits)
        elif mn in ("add", "sub", "and", "or", "xor", "inc", "dec"):
            b = self.tmp(bits, "1" if mn in ("inc", "dec") else self.src(ops[1], bits))
            fn = {"add": "add", "inc": "add", "sub": "sub", "dec": "sub", "and": "and", "or": "or", "xor": "xor"}[mn]
            old = self.tmp(bits, f"__atomic_fetch_{fn}({p}, {b}, __ATOMIC_SEQ_CST)")
            op = {"add": "+", "sub": "-", "and": "&", "or": "|", "xor": "^"}[fn]
            r = self.tmp(bits, f"{old} {op} {b}")
            if mn in ("add",):
                self.flags_add(old, b, r, bits)
            elif mn == "sub":
                self.flags_sub(old, b, r, bits)
            elif mn in ("inc", "dec"):
                edge = (1 << (bits - 1)) if mn == "inc" else (1 << (bits - 1)) - 1
                self.e(f"of = {r} == ({T[bits]}){edge:#x}ULL;")
                self.flags_zs(r, bits)
                self.fd = ("zs", bits, r)
            else:
                self.flags_logic(r, bits)
        else:
            raise self.err("locked instruction not supported")

    def i_mfence(self, insn, ops):
        self.e("__atomic_thread_fence(__ATOMIC_SEQ_CST);")

    i_lfence = i_mfence
    i_sfence = i_mfence

    def i_pause(self, insn, ops):
        self.e("__asm__ volatile(\"yield\" ::: \"memory\");")

    def rep_stos(self, insn, ops):
        # one string instruction: its stores may happen in any order among themselves (x86 fast strings), so the
        # bulk is written 16 bytes at a time
        size = {"b": 1, "w": 2, "d": 4, "q": 8}[insn.mnemonic[-1]]
        if self.f.unit:
            self.e(f"gfill(O, rdi, rax, {size}, rcx);")
        elif self.ordered:
            self.e(f"ofill(O, V, rdi, rax, {size}, rcx);")
        else:
            self.e(f"gfill(V, rdi, rax, {size}, rcx);")
        self.e(f"rdi += rcx * {size};")
        self.e("rcx = 0;")

    # SSE: 128-bit registers as clang vectors (u128 = two 64-bit lanes, cast to other lane types per operation), so
    # that they stay in NEON registers and lane operations become NEON instructions
    def xsrc(self, op):
        if op.type == X.X86_OP_REG:
            return self.reg(op)[0]
        return self.load(op, 128)

    def xbin(self, ops, lane, expr):
        # dst = expr(a, b) on lanes of type lane (v16b, v8w, v8ws, v4d, v4ds, u128)
        a = self.tmp(128, self.reg(ops[0])[0])
        b = self.tmp(128, self.xsrc(ops[1]))
        self.wreg(ops[0], f"(u128)({expr(f'(({lane}){a})', f'(({lane}){b})')})")

    def i_movd(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG and self.reg(d)[1] == 128:
            self.wreg(d, f"(u128)(v4d){{(uint32_t){self.src(s, 32)}, 0, 0, 0}}")
        else:
            self.dst(d, f"((v4d){self.reg(s)[0]})[0]", 32)

    def i_movq(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG and self.reg(d)[1] == 128:
            if s.type == X.X86_OP_REG and self.reg(s)[1] == 128:
                self.wreg(d, f"(u128){{{self.reg(s)[0]}[0], 0}}")
            else:
                self.wreg(d, f"(u128){{{self.src(s, 64)}, 0}}")
        else:
            self.dst(d, f"{self.reg(s)[0]}[0]", 64)

    def i_movups(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG:
            self.wreg(d, self.xsrc(s))
        else:
            self.store(d, self.reg(s)[0], 128)

    # AVX moves: a 256-bit register is xN (low) and yN (high); a VEX-encoded 128-bit write clears the high half
    def ymm(self, op):
        return self.reg(op)[0], "y" + self.reg(op)[0][1:]

    def mem_plus(self, op, k):
        # the same memory operand k bytes further
        a = self.address(op)
        expr, kind = self.guest_addr(a)
        if kind == "h":
            return kind, f"{expr} + {k}"
        return kind, f"({expr}) + {k}"

    def i_vmovdqu(self, insn, ops):
        d, s = ops
        wide = d.size == 32
        if d.type == X.X86_OP_REG and s.type == X.X86_OP_REG:
            dx, dy = self.ymm(d)
            sx, sy = self.ymm(s)
            self.e(f"{dx} = {sx}; {dy} = {sy if wide else '(u128){0, 0}'};")
        elif d.type == X.X86_OP_REG:
            dx, dy = self.ymm(d)
            a = self.address(s)
            expr, kind = self.guest_addr(a)
            if a[0] == "dyn" and kind != "h":
                expr = self.tmp(64, expr)
            lo = self.tmp(128, self.ld(kind, 128, expr))
            hi = self.tmp(128, self.ld(kind, 128, f"{expr} + 16")) if wide else "(u128){0, 0}"
            self.e(f"{dx} = {lo}; {dy} = {hi};")
        else:
            sx, sy = self.ymm(s)
            a = self.address(d)
            expr, kind = self.guest_addr(a)
            if a[0] == "dyn" and kind != "h":
                expr = self.tmp(64, expr)
            self.e(self.st(kind, 128, expr, sx))
            if wide:
                self.e(self.st(kind, 128, f"{expr} + 16", sy))

    i_vmovdqa = i_vmovdqu
    i_vmovups = i_vmovdqu
    i_vmovaps = i_vmovdqu
    i_vmovntdq = i_vmovdqu

    def i_vmovd(self, insn, ops):
        self.i_movd(insn, ops)
        if ops[0].type == X.X86_OP_REG and self.reg(ops[0])[1] >= 128:
            self.e(f"{self.ymm(ops[0])[1]} = (u128){{0, 0}};")

    def i_vmovq(self, insn, ops):
        self.i_movq(insn, ops)
        if ops[0].type == X.X86_OP_REG and self.reg(ops[0])[1] >= 128:
            self.e(f"{self.ymm(ops[0])[1]} = (u128){{0, 0}};")

    def i_vpbroadcastb(self, insn, ops):
        s = self.tmp(128, self.xsrc(ops[1]) if ops[1].type == X.X86_OP_REG else f"(u128)(v16b){{{self.src(ops[1], 8)}}}")
        idx = ", ".join("0" for k in range(16))
        b = self.tmp(128, f"(u128)__builtin_shufflevector((v16b){s}, (v16b){s}, {idx})")
        dx, dy = self.ymm(ops[0])
        self.e(f"{dx} = {b}; {dy} = {b if ops[0].size == 32 else '(u128){0, 0}'};")

    def i_vzeroupper(self, insn, ops):
        self.e(" ".join(f"y{i} = (u128){{0, 0}};" for i in range(16)))

    def i_rep_movsb(self, insn, ops):
        # forward, byte by byte as x86 defines it; 8 bytes at a time where that gives the same result (the
        # destination not within 8 bytes after the source)
        g = "G" if not self.ordered else "O"
        self.e("if (rdi - rsi >= 8) {")
        self.e("    while (rcx >= 8) {")
        self.e("        " + self.st("g", 64, "rdi", self.ld("g", 64, "rsi")))
        self.e("        rdi += 8; rsi += 8; rcx -= 8;")
        self.e("    }")
        self.e("}")
        self.e("while (rcx) {")
        self.e("    " + self.st("g", 8, "rdi", self.ld("g", 8, "rsi")))
        self.e("    rdi++; rsi++; rcx--;")
        self.e("}")

    i_movaps = i_movups
    i_movdqu = i_movups
    i_movdqa = i_movups
    i_movupd = i_movups
    i_movapd = i_movups

    def i_pxor(self, insn, ops):
        if ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            self.wreg(ops[0], "(u128){0, 0}")
        else:
            self.xbin(ops, "u128", lambda a, b: f"{a} ^ {b}")

    i_xorps = i_pxor

    def i_pand(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"{a} & {b}")

    i_andps = i_pand

    def i_pandn(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"~{a} & {b}")

    def i_por(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"{a} | {b}")

    i_orps = i_por

    def i_punpckldq(self, insn, ops):
        self.xbin(ops, "v4d", lambda a, b: f"__builtin_shufflevector({a}, {b}, 0, 4, 1, 5)")

    def i_punpcklqdq(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"__builtin_shufflevector({a}, {b}, 0, 2)")

    def i_punpcklwd(self, insn, ops):
        self.xbin(ops, "v8w", lambda a, b: f"__builtin_shufflevector({a}, {b}, 0, 8, 1, 9, 2, 10, 3, 11)")

    def i_punpcklbw(self, insn, ops):
        idx = ", ".join(f"{k}, {k + 16}" for k in range(8))
        self.xbin(ops, "v16b", lambda a, b: f"__builtin_shufflevector({a}, {b}, {idx})")

    def i_pshufd(self, insn, ops):
        s = self.tmp(128, self.xsrc(ops[1]))
        imm = ops[2].imm
        idx = ", ".join(str((imm >> (2 * k)) & 3) for k in range(4))
        self.wreg(ops[0], f"(u128)__builtin_shufflevector((v4d){s}, (v4d){s}, {idx})")

    def i_pshuflw(self, insn, ops):
        s = self.tmp(128, self.xsrc(ops[1]))
        imm = ops[2].imm
        idx = ", ".join([str((imm >> (2 * k)) & 3) for k in range(4)] + ["4", "5", "6", "7"])
        self.wreg(ops[0], f"(u128)__builtin_shufflevector((v8w){s}, (v8w){s}, {idx})")

    def i_paddd(self, insn, ops):
        self.xbin(ops, "v4d", lambda a, b: f"{a} + {b}")

    def i_paddw(self, insn, ops):
        self.xbin(ops, "v8w", lambda a, b: f"{a} + {b}")

    def i_paddq(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"{a} + {b}")

    def i_psubd(self, insn, ops):
        self.xbin(ops, "v4d", lambda a, b: f"{a} - {b}")

    def i_psubw(self, insn, ops):
        self.xbin(ops, "v8w", lambda a, b: f"{a} - {b}")

    def i_psubq(self, insn, ops):
        self.xbin(ops, "u128", lambda a, b: f"{a} - {b}")

    def i_pcmpeqd(self, insn, ops):
        self.xbin(ops, "v4d", lambda a, b: f"{a} == {b}")

    def i_pcmpeqb(self, insn, ops):
        self.xbin(ops, "v16b", lambda a, b: f"{a} == {b}")

    def i_pcmpeqw(self, insn, ops):
        self.xbin(ops, "v8w", lambda a, b: f"{a} == {b}")

    def i_pcmpgtd(self, insn, ops):
        self.xbin(ops, "v4ds", lambda a, b: f"{a} > {b}")

    def i_pcmpgtw(self, insn, ops):
        self.xbin(ops, "v8ws", lambda a, b: f"{a} > {b}")

    def i_psubusw(self, insn, ops):
        self.xbin(ops, "v8w", lambda a, b: f"((v8w)({a} > {b})) & ({a} - {b})")

    def i_pmaxsw(self, insn, ops):
        self.xbin(ops, "v8ws", lambda a, b: f"__builtin_elementwise_max({a}, {b})")

    def xshift(self, ops, lane, bits, op):
        if ops[1].type != X.X86_OP_IMM:
            raise self.err("vector shift by a register")
        n = ops[1].imm
        a = self.tmp(128, self.reg(ops[0])[0])
        if n >= bits:
            if op == ">>s":
                self.wreg(ops[0], f"(u128)(((({lane}){a})) >> {bits - 1})")
            else:
                self.wreg(ops[0], "(u128){0, 0}")
            return
        self.wreg(ops[0], f"(u128)(((({lane}){a})) {op.rstrip('s')} {n})")

    def i_pslld(self, insn, ops):
        self.xshift(ops, "v4d", 32, "<<")

    def i_psrld(self, insn, ops):
        self.xshift(ops, "v4d", 32, ">>")

    def i_psrad(self, insn, ops):
        self.xshift(ops, "v4ds", 32, ">>s")

    def i_psllw(self, insn, ops):
        self.xshift(ops, "v8w", 16, "<<")

    def i_psrlw(self, insn, ops):
        self.xshift(ops, "v8w", 16, ">>")

    def i_psllq(self, insn, ops):
        self.xshift(ops, "u128", 64, "<<")

    def i_psrlq(self, insn, ops):
        self.xshift(ops, "u128", 64, ">>")

    def i_psrldq(self, insn, ops):
        n = ops[1].imm
        a = self.tmp(128, self.reg(ops[0])[0])
        idx = ", ".join(str(k + n if k + n < 16 else 16) for k in range(16))
        self.wreg(ops[0], f"(u128)__builtin_shufflevector((v16b){a}, (v16b){{0}}, {idx})")

    def i_pslldq(self, insn, ops):
        n = ops[1].imm
        a = self.tmp(128, self.reg(ops[0])[0])
        idx = ", ".join(str(k - n if k - n >= 0 else 16) for k in range(16))
        self.wreg(ops[0], f"(u128)__builtin_shufflevector((v16b){a}, (v16b){{0}}, {idx})")

    # --- scalar odds and ends -------------------------------------------------------------------------------------
    def i_mul(self, insn, ops):
        bits = self.bits0(ops)
        if bits not in (32, 64):
            raise self.err("mul of this size")
        s = self.tmp(bits, self.src(ops[0], bits))
        if bits == 64:
            p = f"((unsigned __int128)rax * {s})"
            self.e(f"{{ unsigned __int128 p_ = {p}; rax = (uint64_t)p_; rdx = (uint64_t)(p_ >> 64); }}")
        else:
            self.e(f"{{ uint64_t p_ = (uint64_t)(uint32_t)rax * {s}; rax = (uint32_t)p_; rdx = (uint32_t)(p_ >> 32); }}")
        self.e("cf = of = rdx != 0;")
        self.fd = None

    def i_bts(self, insn, ops):
        bits = self.bits0(ops)
        if ops[0].type != X.X86_OP_REG and ops[1].type != X.X86_OP_IMM:
            raise self.err("bts on memory with a register offset")
        a, write = self.rmw(ops[0], bits)
        n = self.tmp(bits, f"{self.src(ops[1], bits)} & {bits - 1}")
        self.e(f"cf = ({a} >> {n}) & 1;")
        write(f"{a} | (({T[bits]})1 << {n})")
        self.fd = None

    def i_bt(self, insn, ops):
        bits = self.bits0(ops)
        if ops[0].type != X.X86_OP_REG and ops[1].type != X.X86_OP_IMM:
            raise self.err("bt on memory with a register offset")
        a = self.tmp(bits, self.src(ops[0], bits))
        n = self.tmp(bits, f"{self.src(ops[1], bits)} & {bits - 1}")
        self.e(f"cf = ({a} >> {n}) & 1;")
        self.fd = None

    def prefetch(self, insn, ops):
        a = self.address(ops[0])
        if a[0] == "dyn":
            self.e(f"__builtin_prefetch(V + {a[1]});")

    i_prefetcht0 = prefetch
    i_prefetcht1 = prefetch
    i_prefetcht2 = prefetch
    i_prefetchnta = prefetch
    i_prefetchw = prefetch

    # BMI2: shifts without flags, count masked to the operand size
    def bmi_shift(self, ops, op, signed=False):
        bits = self.bits0(ops)
        s = self.tmp(bits, self.src(ops[1], bits))
        n = self.tmp(bits, f"{self.src(ops[2], bits)} & {bits - 1}")
        if signed:
            self.wreg(ops[0], f"({T[bits]})(({S[bits]}){s} >> {n})")
        else:
            self.wreg(ops[0], f"({T[bits]})({s} {op} {n})")

    def i_shlx(self, insn, ops):
        self.bmi_shift(ops, "<<")

    def i_shrx(self, insn, ops):
        self.bmi_shift(ops, ">>")

    def i_sarx(self, insn, ops):
        self.bmi_shift(ops, ">>", True)

    def i_bzhi(self, insn, ops):
        bits = self.bits0(ops)
        s = self.tmp(bits, self.src(ops[1], bits))
        n = self.tmp(8, f"(uint8_t){self.src(ops[2], bits)}")
        r = self.tmp(bits, f"{n} >= {bits} ? {s} : ({T[bits]})({s} & ((({T[bits]})1 << {n}) - 1))")
        self.wreg(ops[0], r)
        self.e(f"cf = {n} > {bits - 1};")
        self.flags_zs(r, bits)
        self.e("of = 0;")
        self.fd = None

    def i_andn(self, insn, ops):
        bits = self.bits0(ops)
        r = self.tmp(bits, f"~{self.src(ops[1], bits)} & {self.src(ops[2], bits)}")
        self.wreg(ops[0], r)
        self.flags_logic(r, bits)

    def i_bswap(self, insn, ops):
        bits = self.bits0(ops)
        fn = "__builtin_bswap64" if bits == 64 else "__builtin_bswap32"
        self.wreg(ops[0], f"{fn}({self.src(ops[0], bits)})")

    def i_lzcnt(self, insn, ops):
        bits = self.bits0(ops)
        a = self.tmp(bits, self.src(ops[1], bits))
        fn = "__builtin_clzll" if bits == 64 else "__builtin_clz"
        r = self.tmp(bits, f"{a} ? ({T[bits]}){fn}({a}) : {bits}")
        self.wreg(ops[0], r)
        self.e(f"cf = {a} == 0; zf = {r} == 0;")
        self.fd = None

    # --- whole program -------------------------------------------------------------------------------------------------
    def program(self, roots):
        out = [PRELUDE]
        pie = self.elf.pie
        # static, so that translated code reaches it PC-relative instead of through the GOT; FEX sets it by aot_set_base
        out.append("// where a position-independent program was loaded: FEX sets it before anything runs (0 otherwise)")
        out.append("static uint64_t aot_base;")
        out.append("void aot_set_base(uint64_t base) { aot_base = base; }")
        out.append(f"const uint8_t aot_pie = {1 if pie else 0};")
        funcs = list(self.funcs.values())
        for k, f in enumerate(funcs):
            f.index = k
        init = ", ".join("1" if getattr(f, "start_ordered", False) else "0" for f in funcs)
        out.append(f"static volatile uint8_t aot_mode[{len(funcs)}] = {{{init}}}; // 1: the function runs its ordered variant")
        params = ", ".join(f"uint64_t {a}" for a in ARGS)
        for pre in ("f_", "o_"):
            for f in funcs:
                attr = "static inline __attribute__((always_inline))" if f.nstack else "static"
                out.append(f"{attr} uint64_t {pre}{f.name}(struct aot_ctx *c, uint8_t *V, uint64_t gsp, uint8_t *A, {params});")
        # Entry points and indirect calls go through these tables, so that no function is inlined into them: a host pc
        # in translated code then lies in the body of the function it belongs to (aot_escalate)
        for pre in ("f_", "o_"):
            out.append(f"static uint64_t (*const volatile aot_fn_{pre[0]}[{len(funcs)}])(struct aot_ctx *, uint8_t *, uint64_t, "
                       f"uint8_t *, {', '.join('uint64_t' for a in ARGS)}) = {{" + ", ".join(f"{pre}{f.name}" for f in funcs) + "};")
        for pre in ("f_", "o_"):
            out.append(f"static uint64_t aot_dispatch_{pre[0]}(struct aot_ctx *c, uint8_t *V, uint64_t t, uint64_t gsp, {params})")
            out.append("{")
            out.append("    switch (t - aot_base) {" if pie else "    switch (t) {")
            for f in funcs:
                if not f.nstack:
                    out.append(f"    case {f.start:#x}ULL: return aot_fn_{pre[0]}[{f.index}](c, V, gsp, 0, {self.call_args()});")
            out.append(f"    default: return aot_guest_call(c, t, gsp, {self.call_args()});")
            out.append("    }")
            out.append("}")
        for ordered in (False, True):
            for f in funcs:
                out.extend(self.lift(f, ordered))
                out.append("")
        # For FEX: which function a host pc of a plain variant belongs to (it met shared memory there)
        # returns the name of the function switched to its ordered variant, or 0 if it already was
        out.append("const char *aot_escalate(uint64_t pc)")
        out.append("{")
        out.append("    static void *const fn[] = {" + ", ".join(f"(void *)f_{f.name}" for f in funcs) + "};")
        out.append("    static const char *const name[] = {" + ", ".join(f'"{f.name}"' for f in funcs) + "};")
        out.append("    int best = -1;")
        out.append(f"    for (int k = 0; k < {len(funcs)}; k++)")
        out.append("        if ((uint64_t)(uintptr_t)fn[k] <= pc && (best < 0 || (uintptr_t)fn[k] > (uintptr_t)fn[best]))")
        out.append("            best = k;")
        out.append("    if (best < 0 || aot_mode[best])")
        out.append("        return 0;")
        out.append("    aot_mode[best] = 1;")
        out.append("    return name[best];")
        out.append("}")
        out.append("void aot_order_all(void)")
        out.append("{")
        out.append(f"    for (int k = 0; k < {len(funcs)}; k++)")
        out.append("        aot_mode[k] = 1;")
        out.append("}")
        out.append("// without ordering (FEX's TSO off): no function starts ordered")
        out.append("void aot_order_reset(void)")
        out.append("{")
        out.append(f"    for (int k = 0; k < {len(funcs)}; k++)")
        out.append("        aot_mode[k] = 0;")
        out.append("}")
        # entry points for FEX: guest rsp at the call (stack arguments above it), the thread's own guest stack for
        # translated code, the argument registers
        for f in self.funcs.values():
            out.append(f"static uint64_t e_{f.name}(struct aot_ctx *c, uint64_t rsp, uint64_t stack, const uint64_t *a)")
            out.append("{")
            out.append(f"    return aot_fn_f[{f.index}](c, c->view, stack, c->view + rsp + 8, a[0], a[1], a[2], a[3], a[4], a[5]);")
            out.append("}")
        out.append("const struct aot_entry aot_table[] = {")
        for f in self.funcs.values():
            if roots and f.name not in roots and f.name.rsplit("_", 1)[0] not in roots:
                continue
            out.append(f"    {{{f.start:#x}ULL, {f.size}, {fnv(f.hashed):#x}ULL, e_{f.name}, \"{f.name}\"}},")
        out.append("    {0, 0, 0, 0, 0},")
        out.append("};")
        return "\n".join(out) + "\n"


import os

ESC_GUEST = os.environ.get("ESC_GUEST") == "1"  # keep all stack objects on the guest stack


def insn_is_rsp(insn, op):
    return op.type == X.X86_OP_REG and REGS[insn.reg_name(op.reg)][0] == "rsp"


PRELUDE = r"""// Generated by aot/lift.py: x86-64 functions translated to C. Do not edit.
#include <stdbool.h>
#include <stdint.h>
#include "aot.h"

// xmm registers: 128-bit vectors, viewed per operation with the lane type it needs
typedef uint64_t u128 __attribute__((vector_size(16)));
typedef uint8_t v16b __attribute__((vector_size(16)));
typedef uint16_t v8w __attribute__((vector_size(16)));
typedef int16_t v8ws __attribute__((vector_size(16)));
typedef uint32_t v4d __attribute__((vector_size(16)));
typedef int32_t v4ds __attribute__((vector_size(16)));
typedef uint16_t u16u __attribute__((aligned(1)));
typedef uint32_t u32u __attribute__((aligned(1)));
typedef uint64_t u64u __attribute__((aligned(1)));
typedef uint64_t u128u __attribute__((vector_size(16), aligned(1)));

// guest memory, ordered among themselves (volatile)
static inline uint8_t gld8(uint8_t *V, uint64_t a) { return *(volatile uint8_t *)(V + a); }
static inline uint16_t gld16(uint8_t *V, uint64_t a) { return *(volatile u16u *)(V + a); }
static inline uint32_t gld32(uint8_t *V, uint64_t a) { return *(volatile u32u *)(V + a); }
static inline uint64_t gld64(uint8_t *V, uint64_t a) { return *(volatile u64u *)(V + a); }
static inline u128 gld128(uint8_t *V, uint64_t a) { return *(volatile u128u *)(V + a); }
static inline void gst8(uint8_t *V, uint64_t a, uint8_t v) { *(volatile uint8_t *)(V + a) = v; }
static inline void gst16(uint8_t *V, uint64_t a, uint16_t v) { *(volatile u16u *)(V + a) = v; }
static inline void gst32(uint8_t *V, uint64_t a, uint32_t v) { *(volatile u32u *)(V + a) = v; }
static inline void gst64(uint8_t *V, uint64_t a, uint64_t v) { *(volatile u64u *)(V + a) = v; }
static inline void gst128(uint8_t *V, uint64_t a, u128 v) { *(volatile u128u *)(V + a) = v; }
// rep stos: n elements of size bytes (the low bytes of v), 16 bytes per store; the stores stay the library's own
// (volatile, not a call to memset), so that a fault under the page protocol comes from translated code
static inline void gfill(uint8_t *B, uint64_t a, uint64_t v, unsigned size, uint64_t n)
{
    const uint64_t bytes = n * size;
    const uint64_t pat = size == 1   ? (v & 0xff) * 0x0101010101010101ULL
                         : size == 2 ? (v & 0xffff) * 0x0001000100010001ULL
                         : size == 4 ? (v & 0xffffffffULL) * 0x0000000100000001ULL
                                     : v;
    const u128 q = {pat, pat};
    uint8_t *p = B + a;
    uint64_t i = 0;
    for (; i + 16 <= bytes; i += 16)
        *(volatile u128u *)(p + i) = q;
    for (; i + 8 <= bytes; i += 8)
        *(volatile u64u *)(p + i) = pat;
    for (; i < bytes; i++)
        *(volatile uint8_t *)(p + i) = (uint8_t)(pat >> ((i & 7) * 8)); // the pattern repeats within 8 bytes
}
// read-only guest data (tables in read-only segments): immutable, so neither ordered nor through the views
static inline uint8_t rld8(uint8_t *V, uint64_t a) { (void)V; return *(const uint8_t *)(uintptr_t)a; }
static inline uint16_t rld16(uint8_t *V, uint64_t a) { (void)V; return *(const u16u *)(uintptr_t)a; }
static inline uint32_t rld32(uint8_t *V, uint64_t a) { (void)V; return *(const u32u *)(uintptr_t)a; }
static inline uint64_t rld64(uint8_t *V, uint64_t a) { (void)V; return *(const u64u *)(uintptr_t)a; }
static inline u128 rld128(uint8_t *V, uint64_t a) { (void)V; return *(const u128u *)(uintptr_t)a; }
// host memory: stack slots that never escape, incoming stack arguments
static inline uint8_t hld8(const uint8_t *p) { return *p; }
static inline uint16_t hld16(const uint8_t *p) { uint16_t v; __builtin_memcpy(&v, p, 2); return v; }
static inline uint32_t hld32(const uint8_t *p) { uint32_t v; __builtin_memcpy(&v, p, 4); return v; }
static inline uint64_t hld64(const uint8_t *p) { uint64_t v; __builtin_memcpy(&v, p, 8); return v; }
static inline u128 hld128(const uint8_t *p) { u128 v; __builtin_memcpy(&v, p, 16); return v; }
static inline void hst8(uint8_t *p, uint8_t v) { *p = v; }
static inline void hst16(uint8_t *p, uint16_t v) { __builtin_memcpy(p, &v, 2); }
static inline void hst32(uint8_t *p, uint32_t v) { __builtin_memcpy(p, &v, 4); }
static inline void hst64(uint8_t *p, uint64_t v) { __builtin_memcpy(p, &v, 8); }
static inline void hst128(uint8_t *p, u128 v) { __builtin_memcpy(p, &v, 16); }

// guest memory in the ordered variant: the ordered view, x86 order kept. Loads acquire (`ldapr`), stores release
// (`stlr`); unaligned, a load is followed by `dmb ishld` and a store preceded by `dmb ish`, which orders them the
// same way. (Reading the covering aligned words with `ldapr` instead was slower for zstd: 725 -> 782 ms, notes
// section 21.) With views, guest addresses lie below 2^34; a larger value is the address of a stack object kept in
// host memory (relative to the plain view, private to the thread): plain.
#define HOSTOBJ(a) __builtin_expect(((a) >> 34) != 0 && O != V, 0)
#ifndef AOT_WORDS
#define AOT_WORDS 0 // unaligned loads of this many bytes and more read the covering aligned words with ldapr
#endif
#define ORDERED(bits, T)                                                                                               \
    static inline T old##bits(uint8_t *O, uint8_t *V, uint64_t a)                                                      \
    {                                                                                                                  \
        if (HOSTOBJ(a))                                                                                                \
            return *(volatile T##u *)(V + a);                                                                          \
        if (__builtin_expect((a & (bits / 8 - 1)) == 0, 1))                                                            \
            return __atomic_load_n((T *)(O + a), __ATOMIC_ACQUIRE);                                                    \
        if (AOT_WORDS && bits / 8 >= AOT_WORDS) {                                                                      \
            const uint64_t lo = a & ~7ULL;                                                                             \
            const unsigned sh = (unsigned)(a & 7) * 8;                                                                 \
            const uint64_t w0 = __atomic_load_n((uint64_t *)(O + lo), __ATOMIC_ACQUIRE);                               \
            if ((a & 7) + bits / 8 <= 8)                                                                               \
                return (T)(w0 >> sh);                                                                                  \
            const uint64_t w1 = __atomic_load_n((uint64_t *)(O + lo + 8), __ATOMIC_ACQUIRE);                           \
            return (T)((w0 >> sh) | (w1 << (64 - sh)));                                                                \
        }                                                                                                              \
        T v = *(volatile T##u *)(O + a);                                                                               \
        __asm__ volatile("dmb ishld" ::: "memory");                                                                    \
        return v;                                                                                                      \
    }                                                                                                                  \
    static inline void ost##bits(uint8_t *O, uint8_t *V, uint64_t a, T v)                                              \
    {                                                                                                                  \
        if (HOSTOBJ(a)) {                                                                                              \
            *(volatile T##u *)(V + a) = v;                                                                             \
            return;                                                                                                    \
        }                                                                                                              \
        if (__builtin_expect((a & (bits / 8 - 1)) == 0, 1)) {                                                          \
            __atomic_store_n((T *)(O + a), v, __ATOMIC_RELEASE);                                                       \
            return;                                                                                                    \
        }                                                                                                              \
        __asm__ volatile("dmb ish" ::: "memory");                                                                      \
        *(volatile T##u *)(O + a) = v;                                                                                 \
    }
typedef uint8_t uint8_tu;
typedef u16u uint16_tu;
typedef u32u uint32_tu;
typedef u64u uint64_tu;
ORDERED(8, uint8_t)
ORDERED(16, uint16_t)
ORDERED(32, uint32_t)
ORDERED(64, uint64_t)
// 16 bytes (SSE moves): two ordered 8-byte halves, in address order
static inline u128 old128(uint8_t *O, uint8_t *V, uint64_t a)
{
    uint64_t lo = old64(O, V, a), hi = old64(O, V, a + 8);
    return (u128){lo, hi};
}
static inline void ost128(uint8_t *O, uint8_t *V, uint64_t a, u128 v)
{
    ost64(O, V, a, v[0]);
    ost64(O, V, a + 8, v[1]);
}
// rep stos ordered: the string's stores after every earlier access, in any order among themselves; every later
// store is a release or follows a barrier, which keeps them before it
static inline void ofill(uint8_t *O, uint8_t *V, uint64_t a, uint64_t v, unsigned size, uint64_t n)
{
    if (HOSTOBJ(a)) {
        gfill(V, a, v, size, n);
        return;
    }
    __asm__ volatile("dmb ish" ::: "memory");
    gfill(O, a, v, size, n);
}

__attribute__((noreturn, cold)) void aot_unreachable(uint64_t rip);

static inline uint64_t aot_guest_call(struct aot_ctx *c, uint64_t target, uint64_t rsp, uint64_t rdi, uint64_t rsi,
                                      uint64_t rdx, uint64_t rcx, uint64_t r8, uint64_t r9)
{
    const uint64_t a[6] = {rdi, rsi, rdx, rcx, r8, r9};
    return c->guest_call(c, target, rsp, a);
}
"""


def main():
    binary, out = sys.argv[1], sys.argv[2]
    names = sys.argv[3:]
    roots = None
    if "--roots" in names:
        k = names.index("--roots")
        roots = set(names[k + 1:])
        names = names[:k]
    # String functions (glibc's memmove, memset): translated as units, ordered against what comes before and after
    # them, their own accesses in any order (see Lifter.lift). --strings NAME...: routed for FEX's code as well;
    # --internal NAME...: called from translated code only (a call from the JIT pays the bridge)
    # --ordered NAME...: these (listed among the functions as well) start in their ordered variant, for functions
    # that read shared data throughout (one inline ldapr per access instead of a patched stub each)
    start_ordered = set()
    if "--ordered" in names:
        k = names.index("--ordered")
        rest = names[k + 1:]
        stop = next((i for i, n in enumerate(rest) if n.startswith("--")), len(rest))
        start_ordered = set(rest[:stop])
        names = names[:k] + rest[stop:]
    units = set()
    for opt in ("--strings", "--internal"):
        if opt in names:
            k = names.index(opt)
            rest = names[k + 1:]
            stop = next((i for i, n in enumerate(rest) if n.startswith("--")), len(rest))
            listed = rest[:stop]
            names = names[:k] + rest[stop:] + listed
            units.update(listed)
            if opt == "--internal":
                internal = set(listed)
                keep = [n for n in names if n not in internal]
                roots = set(n.split("@")[0] for n in keep) if roots is None else roots
    elf = Elf(binary)
    try:
        funcs = [Function(elf, n) for n in names]
        for f, n in zip(funcs, names):
            f.unit = n in units
            f.start_ordered = n in start_ordered
        lifter = Lifter(elf, funcs)
        text = lifter.program(roots)
    except LiftError as e:
        sys.exit(f"lift: {e}")
    if lifter.problems:
        seen = set()
        for p in lifter.problems:
            if p not in seen:
                seen.add(p)
                print("lift:", p, file=sys.stderr)
        sys.exit(f"lift: {len(seen)} problems")
    open(out, "w").write(text)
    for f in funcs:
        objs = ""
        if f.esc:
            objs = f"  stack objects {f.esc[0]}..{f.esc[1]} " + ("in host memory" if f.esc_host else "on the guest stack (address escapes)")
        pe = f"  escaping args {','.join(ARGS[i] for i in sorted(f.param_escapes))}" if f.param_escapes else ""
        print(f"{f.name:28s} {f.start:#x} {len(f.insns):5d} insns  frame {f.frame_size:4d}  stack args {f.nstack:3d}{objs}{pe}")


if __name__ == "__main__":
    main()

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
        self.syms = {}
        for line in subprocess.run(["nm", "-S", path], capture_output=True, text=True).stdout.splitlines():
            p = line.split()
            if len(p) == 4 and p[2] in "tTwW":
                self.syms[p[3]] = (int(p[0], 16), int(p[1], 16))
        self.by_addr = {a: n for n, (a, s) in self.syms.items()}

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
    def __init__(self, elf, name):
        self.elf = elf
        self.name = name
        self.start, self.size = elf.syms[name]
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        md.detail = True
        self.code = elf.read(self.start, self.size)
        self.insns = list(md.disasm(self.code, self.start))
        if sum(i.size for i in self.insns) != self.size:
            raise LiftError(f"{name}: decoding stopped early")
        self.at = {i.address: i for i in self.insns}
        self.analyse()

    def err(self, insn, msg):
        return LiftError(f"{self.name}+{insn.address - self.start:#x} ({insn.address:#x}: {insn.mnemonic} {insn.op_str}): {msg}")

    def inside(self, a):
        return self.start <= a < self.start + self.size

    def jump_table(self, insn):
        # notrack jmp [idx*8 + table], bounded by an earlier "cmp idx, n; ja default" in the same block
        m = insn.operands[0].mem
        if m.base or not m.index or m.scale != 8:
            raise self.err(insn, "indirect jump that is not a jump table")
        idx = REGS[insn.reg_name(m.index)][0]
        k = self.insns.index(insn)
        # The bound: the nearest "cmp ..., n-1" that is followed by a ja (the compared value may be the memory word the
        # index is loaded from). An index outside the table at run time ends in aot_unreachable, so a bound found
        # too small fails loudly; table entries outside the function fail the translation.
        n = None
        window = self.insns[max(0, k - 8):k]
        for j in range(len(window) - 2, -1, -1):
            prev = window[j]
            if prev.mnemonic == "cmp" and prev.operands[1].type == X.X86_OP_IMM and window[j + 1].mnemonic == "ja":
                n = prev.operands[1].imm + 1
                break
        if n is None:
            raise self.err(insn, "jump table without bound")
        table = m.disp & M64
        targets = [struct.unpack_from("<Q", self.elf.read(table + 8 * j, 8))[0] for j in range(n)]
        for t in targets:
            if not self.inside(t) or t not in self.at:
                raise self.err(insn, f"jump table entry {t:#x} outside the function")
        return idx, targets

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
            self.emit_insn(insn)
        params = ", ".join(f"uint64_t {a}" for a in ARGS)
        head = [f"static uint64_t {self.pre}{f.name}(struct aot_ctx *c, uint8_t *V, uint64_t gsp, uint8_t *A, {params})", "{"]
        decl = []
        if ordered:
            decl.append("    uint8_t *O = c->oview;")
        else:
            decl.append(f"    if (__builtin_expect(aot_mode[{f.index}], 0))")
            decl.append(f"        return o_{f.name}(c, V, gsp, A, {self.call_args()});")
        locs = [r for r in GPRS if r not in ARGS]
        decl.append("    uint64_t " + ", ".join(f"{r} = 0" for r in locs) + ";")
        decl.append("    u128 " + ", ".join(f"x{i} = 0" for i in range(16)) + ";")
        decl.append("    bool cf = 0, zf = 0, sf = 0, of = 0;")
        if f.frame_size:
            decl.append(f"    uint8_t F[{f.frame_size}] __attribute__((aligned(16)));")
        if f.esc_host:
            decl.append(f"    uint8_t E[{(f.esc[1] - f.esc[0] + 15) & ~15}] __attribute__((aligned(16)));")
        decl.append("    (void)c; (void)V; (void)gsp; (void)A;")
        for ty, n in self.temps:
            decl.append(f"    {ty} {n};")
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
        # a table in a read-only segment, indexed by a register (base or index): immutable data
        ro = self.elf.readonly(m.disp & M64) and (m.disp & M64) >= self.elf.segs[0][0]
        return ("dyn", "(" + " + ".join(parts) + ")", ro)

    def esc_base(self):
        # where the stack objects whose address is taken live: on the guest stack, or in a host array that their
        # (guest) addresses reach through the view, V + address; the latter only when the escape analysis shows that
        # these addresses stay in translated code and out of memory
        if self.f.esc_host:
            return f"((uint64_t)(uintptr_t)E - (uint64_t)(uintptr_t)V - {self.f.esc[0] & M64:#x}ULL)"
        return "gsp"

    def lea_value(self, op):
        a = self.address(op)
        if a[0] == "const":
            return f"{a[1]:#x}ULL"
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
            return (f"{a[1]:#x}ULL", "r" if self.elf.readonly(a[1]) else "g")
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
        if a[0] == "const" and self.elf.readonly(a[1], bits // 8):
            v = int.from_bytes(self.elf.read(a[1], bits // 8), "little")
            if bits == 128:
                return f"(((u128){v >> 64:#x}ULL << 64) | {v & M64:#x}ULL)"
            return f"(({T[bits]}){v:#x}ULL)"
        expr, kind = self.guest_addr(a)
        return self.ld(kind, bits, expr)

    # accessors by kind: h host memory, r read-only guest data, s the thread's own guest stack, g guest memory (plain
    # view, or the ordered view in the ordered variant)
    def ld(self, kind, bits, expr):
        if kind == "h":
            return f"hld{bits}({expr})"
        if kind == "r":
            return f"rld{bits}(V, {expr})"
        if kind == "g" and self.ordered:
            return f"old{bits}(O, {expr})"
        return f"gld{bits}(V, {expr})"

    def st(self, kind, bits, expr, value):
        if kind == "h":
            return f"hst{bits}({expr}, {value});"
        if kind == "g" and self.ordered:
            return f"ost{bits}(O, {expr}, {value});"
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

    def direct_call(self, target, gsp_expr, argp_off, tail):
        callee = self.by_start.get(target)
        if callee:
            argp = "A" if tail else self.callee_argp(callee, argp_off)
            return f"{self.pre}{callee.name}(c, V, {gsp_expr}, {argp}, {self.call_args()})"
        return f"aot_guest_call(c, {target:#x}ULL, {gsp_expr}, {self.call_args()})"

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
            idx, targets = self.f.tables[insn.address]
            self.e(f"switch ({idx}) {{")
            for j, t in enumerate(targets):
                self.e(f"case {j}: goto L_{t:x};")
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
            expr = f"{a[1]:#x}ULL"
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
        bits = {"b": 8, "w": 16, "d": 32, "q": 64}[insn.mnemonic[-1]]
        self.e("while (rcx) {")
        self.e("    " + self.st("g", bits, "rdi", f"({T[bits]})rax"))
        self.e(f"    rdi += {bits // 8};")
        self.e("    rcx--;")
        self.e("}")

    # SSE: 128-bit registers as unsigned __int128
    def xsrc(self, op):
        if op.type == X.X86_OP_REG:
            return self.reg(op)[0]
        return self.load(op, 128)

    def i_movd(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG and self.reg(d)[1] == 128:
            self.wreg(d, f"(u128)(uint32_t){self.src(s, 32)}")
        else:
            self.dst(d, f"(uint32_t){self.reg(s)[0]}", 32)

    def i_movq(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG and self.reg(d)[1] == 128:
            if s.type == X.X86_OP_REG and self.reg(s)[1] == 128:
                self.wreg(d, f"(u128)(uint64_t){self.reg(s)[0]}")
            else:
                self.wreg(d, f"(u128){self.src(s, 64)}")
        else:
            self.dst(d, f"(uint64_t){self.reg(s)[0]}", 64)

    def i_movups(self, insn, ops):
        d, s = ops
        if d.type == X.X86_OP_REG:
            self.wreg(d, self.xsrc(s))
        else:
            self.store(d, self.reg(s)[0], 128)

    i_movaps = i_movups
    i_movdqu = i_movups
    i_movdqa = i_movups
    i_movupd = i_movups
    i_movapd = i_movups

    def i_pxor(self, insn, ops):
        if ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            self.wreg(ops[0], "(u128)0")
        else:
            self.wreg(ops[0], f"{self.reg(ops[0])[0]} ^ {self.xsrc(ops[1])}")

    i_xorps = i_pxor

    def i_punpckldq(self, insn, ops):
        a = self.reg(ops[0])[0]
        b = self.tmp(128, self.xsrc(ops[1]))
        self.wreg(ops[0], f"mk4(d32({a}, 0), d32({b}, 0), d32({a}, 1), d32({b}, 1))")

    def i_punpcklqdq(self, insn, ops):
        a = self.reg(ops[0])[0]
        b = self.tmp(128, self.xsrc(ops[1]))
        self.wreg(ops[0], f"(u128)(uint64_t){a} | ((u128)(uint64_t){b} << 64)")

    def i_pshufd(self, insn, ops):
        s = self.tmp(128, self.xsrc(ops[1]))
        imm = ops[2].imm
        self.wreg(ops[0], "mk4(" + ", ".join(f"d32({s}, {(imm >> (2 * k)) & 3})" for k in range(4)) + ")")

    def i_paddd(self, insn, ops):
        a = self.tmp(128, self.reg(ops[0])[0])
        b = self.tmp(128, self.xsrc(ops[1]))
        self.wreg(ops[0], "mk4(" + ", ".join(f"d32({a}, {k}) + d32({b}, {k})" for k in range(4)) + ")")

    # --- whole program -------------------------------------------------------------------------------------------------
    def program(self, roots):
        out = [PRELUDE]
        funcs = list(self.funcs.values())
        for k, f in enumerate(funcs):
            f.index = k
        out.append(f"static volatile uint8_t aot_mode[{len(funcs)}]; // 1: the function runs its ordered variant")
        params = ", ".join(f"uint64_t {a}" for a in ARGS)
        for pre in ("f_", "o_"):
            for f in funcs:
                attr = "static inline __attribute__((always_inline))" if f.nstack else "static"
                out.append(f"{attr} uint64_t {pre}{f.name}(struct aot_ctx *c, uint8_t *V, uint64_t gsp, uint8_t *A, {params});")
        for pre in ("f_", "o_"):
            out.append(f"static uint64_t aot_dispatch_{pre[0]}(struct aot_ctx *c, uint8_t *V, uint64_t t, uint64_t gsp, {params})")
            out.append("{")
            out.append("    switch (t) {")
            for f in funcs:
                if not f.nstack:
                    out.append(f"    case {f.start:#x}ULL: return {pre}{f.name}(c, V, gsp, 0, {self.call_args()});")
            out.append(f"    default: return aot_guest_call(c, t, gsp, {self.call_args()});")
            out.append("    }")
            out.append("}")
        for ordered in (False, True):
            for f in funcs:
                out.extend(self.lift(f, ordered))
                out.append("")
        # For FEX: which function a host pc of a plain variant belongs to (it met shared memory there)
        out.append("void aot_escalate(uint64_t pc)")
        out.append("{")
        out.append("    static void *const fn[] = {" + ", ".join(f"(void *)f_{f.name}" for f in funcs) + "};")
        out.append("    int best = -1;")
        out.append(f"    for (int k = 0; k < {len(funcs)}; k++)")
        out.append("        if ((uint64_t)(uintptr_t)fn[k] <= pc && (best < 0 || (uintptr_t)fn[k] > (uintptr_t)fn[best]))")
        out.append("            best = k;")
        out.append("    if (best >= 0)")
        out.append("        aot_mode[best] = 1;")
        out.append("}")
        out.append("void aot_order_all(void)")
        out.append("{")
        out.append(f"    for (int k = 0; k < {len(funcs)}; k++)")
        out.append("        aot_mode[k] = 1;")
        out.append("}")
        # entry points for FEX: guest rsp at the call (stack arguments above it), the thread's own guest stack for
        # translated code, the argument registers
        for f in self.funcs.values():
            out.append(f"static uint64_t e_{f.name}(struct aot_ctx *c, uint64_t rsp, uint64_t stack, const uint64_t *a)")
            out.append("{")
            out.append(f"    return f_{f.name}(c, c->view, stack, c->view + rsp + 8, a[0], a[1], a[2], a[3], a[4], a[5]);")
            out.append("}")
        out.append("const struct aot_entry aot_table[] = {")
        for f in self.funcs.values():
            if roots and f.name not in roots:
                continue
            out.append(f"    {{{f.start:#x}ULL, {f.size}, {fnv(f.code):#x}ULL, e_{f.name}, \"{f.name}\"}},")
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

typedef unsigned __int128 u128;
typedef uint16_t u16u __attribute__((aligned(1)));
typedef uint32_t u32u __attribute__((aligned(1)));
typedef uint64_t u64u __attribute__((aligned(1)));
typedef u128 u128u __attribute__((aligned(1)));

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

// guest memory in the ordered variant: the ordered view, x86 order kept (acquire loads, release stores; an
// unaligned access between two full barriers)
#define ORDERED(bits, T)                                                                                               \
    static inline T old##bits(uint8_t *O, uint64_t a)                                                                  \
    {                                                                                                                  \
        if (__builtin_expect((a & (bits / 8 - 1)) == 0, 1))                                                            \
            return __atomic_load_n((T *)(O + a), __ATOMIC_ACQUIRE);                                                    \
        __atomic_thread_fence(__ATOMIC_SEQ_CST);                                                                       \
        T v = *(volatile T##u *)(O + a);                                                                               \
        __atomic_thread_fence(__ATOMIC_SEQ_CST);                                                                       \
        return v;                                                                                                      \
    }                                                                                                                  \
    static inline void ost##bits(uint8_t *O, uint64_t a, T v)                                                          \
    {                                                                                                                  \
        if (__builtin_expect((a & (bits / 8 - 1)) == 0, 1)) {                                                          \
            __atomic_store_n((T *)(O + a), v, __ATOMIC_RELEASE);                                                       \
            return;                                                                                                    \
        }                                                                                                              \
        __atomic_thread_fence(__ATOMIC_SEQ_CST);                                                                       \
        *(volatile T##u *)(O + a) = v;                                                                                 \
        __atomic_thread_fence(__ATOMIC_SEQ_CST);                                                                       \
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
static inline u128 old128(uint8_t *O, uint64_t a)
{
    uint64_t lo = old64(O, a), hi = old64(O, a + 8);
    return (u128)lo | ((u128)hi << 64);
}
static inline void ost128(uint8_t *O, uint64_t a, u128 v)
{
    ost64(O, a, (uint64_t)v);
    ost64(O, a + 8, (uint64_t)(v >> 64));
}

static inline uint32_t d32(u128 x, int i) { return (uint32_t)(x >> (32 * i)); }
static inline u128 mk4(uint32_t a, uint32_t b, uint32_t c, uint32_t d)
{
    return (u128)a | ((u128)b << 32) | ((u128)c << 64) | ((u128)d << 96);
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
    elf = Elf(binary)
    try:
        funcs = [Function(elf, n) for n in names]
        lifter = Lifter(elf, funcs)
        text = lifter.program(roots)
    except LiftError as e:
        sys.exit(f"lift: {e}")
    open(out, "w").write(text)
    for f in funcs:
        objs = ""
        if f.esc:
            objs = f"  stack objects {f.esc[0]}..{f.esc[1]} " + ("in host memory" if f.esc_host else "on the guest stack (address escapes)")
        pe = f"  escaping args {','.join(ARGS[i] for i in sorted(f.param_escapes))}" if f.param_escapes else ""
        print(f"{f.name:28s} {f.start:#x} {len(f.insns):5d} insns  frame {f.frame_size:4d}  stack args {f.nstack:3d}{objs}{pe}")


if __name__ == "__main__":
    main()

"""The functions of an x86-64 program: (address, size, name), sorted by address; and the split-off cold parts.

From the symbol table where the program has one (symbols without a size as size 0, as nm lists them). Programs as
distributions ship them are stripped: then the bounds come from the unwind information (.eh_frame: one FDE per
function, which x86-64 compilers emit by default), named by the dynamic symbols where one starts there and by
address otherwise (fn_ADDRESS).

gcc moves the rarely run paths of a function into a part of their own (foo.cold, in .text.unlikely), reached only by
jumps from the function and running in its frame. Such a part is a symbol named *.cold*, or, without symbols, an FDE
whose first row does not have the CFA at rsp+8 as at a function's entry (it starts inside its function's frame).
"""
import os
import re
import subprocess

FDE = re.compile(r"\bFDE\b.*\bpc=([0-9a-f]+)\.\.([0-9a-f]+)")
ROW = re.compile(r"^([0-9a-f]{8,16})\s+(\S+)")


def _nm(args, path):
    out = subprocess.run(["nm", *args, path], capture_output=True, text=True, env=dict(os.environ, LC_ALL="C")).stdout
    syms = []
    for line in out.splitlines():
        p = line.split()
        if len(p) == 4 and p[2] in "tTwW":
            syms.append((int(p[0], 16), int(p[1], 16), p[3]))
        elif len(p) == 3 and p[1] in "tTwW":
            syms.append((int(p[0], 16), 0, p[2]))
    return syms


def _fdes(path):
    """(start, size, the CFA rule of the first row) of every FDE"""
    out = subprocess.run(["readelf", "--debug-dump=frames-interp", path], capture_output=True, text=True,
                         env=dict(os.environ, LC_ALL="C")).stdout
    fdes = {}
    cur = None
    for line in out.splitlines():
        m = FDE.search(line)
        if m:
            lo, hi = int(m.group(1), 16), int(m.group(2), 16)
            cur = (lo, hi - lo) if hi > lo else None
            continue
        r = ROW.match(line)
        if cur and r and int(r.group(1), 16) == cur[0]:
            fdes.setdefault(cur, r.group(2))
            cur = None
    return sorted((lo, size, cfa) for (lo, size), cfa in fdes.items())


_cache = {}


def _info(path):
    if path not in _cache:
        syms = _nm(["-S"], path)
        if syms:
            funcs = sorted(syms)
            cold = sorted((a, s) for a, s, n in syms if ".cold" in n and s > 0)
        else:
            dyn = {a: n.split("@")[0] for a, s, n in _nm(["-D", "-S"], path) if s > 0}  # without the symbol version
            fdes = _fdes(path)
            funcs = [(a, size, dyn.get(a, f"fn_{a:x}")) for a, size, cfa in fdes if cfa == "rsp+8"]
            cold = [(a, size) for a, size, cfa in fdes if cfa != "rsp+8"]
        _cache[path] = (funcs, cold)
    return _cache[path]


def functions(path):
    return _info(path)[0]


def cold_parts(path):
    """(start, size) of the split-off cold parts"""
    return _info(path)[1]

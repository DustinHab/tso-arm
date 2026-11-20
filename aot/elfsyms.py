"""The functions of an x86-64 program: (address, size, name), sorted by address.

From the symbol table where the program has one (symbols without a size as size 0, as nm lists them). Programs as
distributions ship them are stripped: then the bounds come from the unwind information (.eh_frame: one FDE per
function, which x86-64 compilers emit by default), named by the dynamic symbols where one starts there and by
address otherwise (fn_ADDRESS).
"""
import os
import re
import subprocess

FDE = re.compile(r"\bFDE\b.*\bpc=([0-9a-f]+)\.\.([0-9a-f]+)")


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
    out = subprocess.run(["readelf", "--debug-dump=frames", path], capture_output=True, text=True,
                         env=dict(os.environ, LC_ALL="C")).stdout
    ranges = set()
    for line in out.splitlines():
        m = FDE.search(line)
        if m:
            lo, hi = int(m.group(1), 16), int(m.group(2), 16)
            if hi > lo:
                ranges.add((lo, hi - lo))
    return sorted(ranges)


def functions(path):
    syms = _nm(["-S"], path)
    if syms:
        return sorted(syms)
    dyn = {a: n.split("@")[0] for a, s, n in _nm(["-D", "-S"], path) if s > 0}  # without the symbol version
    return [(a, size, dyn.get(a, f"fn_{a:x}")) for a, size in _fdes(path)]

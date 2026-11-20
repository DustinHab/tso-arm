#!/usr/bin/env python3
"""Cycles per guest function in two perf reports of the same program (`perf report --sort sym --stdio`): one run
with translated functions (o_NAME, f_NAME in the library), one with FEX's code alone (FEX_BLOCKJITNAMING=1 names
its blocks BINARY+0xOFFSET). A markdown table, hottest first: millions of cycles in each run and their ratio.
  tools/perf_guest.py BINARY REPORT_WITH CYCLES_WITH REPORT_WITHOUT CYCLES_WITHOUT [N]
"""
import bisect
import collections
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "aot"))
import auto  # noqa: E402  (symbols, load_base)


def shares(path, binary, syms, base):
    addrs = [a for a, _ in syms]
    pat = re.compile(re.escape(os.path.basename(binary)) + r"\+0x([0-9a-f]+)")
    out = collections.Counter()
    for line in open(path, errors="replace"):
        if line.startswith("#") or "%" not in line:
            continue
        try:
            pct = float(line.split()[0].rstrip("%"))
        except ValueError:
            continue
        m = pat.search(line)
        if m:
            i = bisect.bisect_right(addrs, base + int(m.group(1), 16)) - 1
            name = syms[i][1].replace("@", "_") if i >= 0 else "?"
        else:
            name = line.split("] ", 1)[-1].strip()
            if name[:2] in ("o_", "f_"):
                name = name[2:]
            else:
                name = "(" + name[:40] + ")"
        out[name] += pct
    return out


def main():
    binary, rw, cw, ro, co = sys.argv[1:6]
    n = int(sys.argv[6]) if len(sys.argv) > 6 else 15
    syms, base = auto.symbols(binary), auto.load_base(binary)
    w, o = shares(rw, binary, syms, base), shares(ro, binary, syms, base)
    cw, co = float(cw), float(co)
    print("| function | translated + FEX, M cycles | FEX alone, M cycles | ratio |")
    print("|---|---|---|---|")
    for name in sorted(set(w) | set(o), key=lambda k: -max(w[k] * cw, o[k] * co))[:n]:
        a, b = w[name] * cw / 1e8, o[name] * co / 1e8
        print(f"| {name} | {a:.0f} | {b:.0f} | {a / b:.2f} |" if b else f"| {name} | {a:.0f} | {b:.0f} | - |")


if __name__ == "__main__":
    main()

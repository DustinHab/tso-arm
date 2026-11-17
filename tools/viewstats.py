#!/usr/bin/env python3
"""Counts, in a FEX IR dump (FEX_DUMPIR=stderr FEX_PASSMANAGERDUMPIR=afteropt), which ops consume ViewPlain nodes,
how often LoadMem/StoreMem carry the Viewed flag, and the shapes of their offsets."""
import collections
import re
import sys

text = open(sys.argv[1], errors="replace").read()
views = {}  # node id -> line
consumers = collections.Counter()
mem = collections.Counter()
for line in text.splitlines():
    m = re.search(r"%(\d+)(\([^)]*\))? i64 = ViewPlain", line)
    if m:
        views[m.group(1)] = line
        continue
    m = re.search(r"= (\w+) (.*)$", line) or re.search(r"\) (\w+) (.*)$", line)
    if not m:
        continue
    op, args = m.group(1), m.group(2)
    if op in ("LoadMem", "StoreMem"):
        viewed = args.rstrip().endswith("#0x1")
        offset = "inline" if re.search(r", %\d+, i\d+, (SXTX|UXTW|SXTW)", args) else "?"
        mem[(op, "Viewed" if viewed else "plain-arg")] += 1
    for ref in re.findall(r"%(\d+)", args):
        if ref in views:
            consumers[op] += 1
print("ViewPlain nodes:", len(views))
for op, n in consumers.most_common(20):
    print(f"  consumed by {op:28} {n}")
for k, n in sorted(mem.items()):
    print("  ", k, n)

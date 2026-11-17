#!/usr/bin/env python3
"""Lists FEX IR ops whose arguments include a memory address (from FEXCore/Source/Interface/IR/IR.json)."""
import json
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "FEXCore/Source/Interface/IR/IR.json"
text = open(path).read()
# IR.json allows comments-free JSON; keys are op signatures
d = json.loads(text)
for group, ops in d["Ops"].items():
    for sig, body in ops.items():
        args = re.findall(r"(\w+):([#$])(\w+)", sig)
        names = [n for (_, _, n) in args]
        if any(re.search(r"Addr|Address|Ptr", n) for n in names):
            print(f"{group:16} {sig}")

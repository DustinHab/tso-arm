#!/usr/bin/env python3
"""Adds the 'Viewed' flag to the LoadMem and StoreMem IR ops (run in the FEX source root)."""
import pathlib

p = pathlib.Path("FEXCore/Source/Interface/IR/IR.json")
t = p.read_text()
sigs = [
    '"SSA = LoadMem RegisterClass:$Class, OpSize:#Size, GPR:$Addr, GPR:$Offset, OpSize:$Align, MemOffsetType:$OffsetType, u8:$OffsetScale"',
    '"StoreMem RegisterClass:$Class, OpSize:#Size, SSA:$Value, GPR:$Addr, GPR:$Offset, OpSize:$Align, MemOffsetType:$OffsetType, u8:$OffsetScale"',
]
for sig in sigs:
    if t.count(sig) != 1:
        raise SystemExit("not found: " + sig)
    t = t.replace(sig, sig[:-1] + ', i1:$Viewed{false}"')
p.write_text(t)
print("ok")

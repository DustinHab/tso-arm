#!/usr/bin/env python3
"""Puts a table into README.md between its markers: out/efficiency.md (from bench/efficiency.sh) between the
efficiency markers, or with arguments another table between other markers.
  tools/readme_efficiency.py [TABLE.md [MARKER]]      (MARKER: efficiency, distro)"""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
table = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / "out" / "efficiency.md").read_text(encoding="utf-8").strip()
marker = sys.argv[2] if len(sys.argv) > 2 else "efficiency"
readme = root / "README.md"
text = readme.read_text(encoding="utf-8")
begin, end = f"<!-- {marker}:begin -->", f"<!-- {marker}:end -->"
if begin not in text:
    raise SystemExit(f"README.md has no {marker} markers")
head, rest = text.split(begin, 1)
_, tail = rest.split(end, 1)
readme.write_text(head + begin + "\n" + table + "\n" + end + tail, encoding="utf-8", newline="\n")
print("README.md updated")

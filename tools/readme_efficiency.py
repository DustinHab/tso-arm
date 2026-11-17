#!/usr/bin/env python3
"""Puts out/efficiency.md (from bench/efficiency.sh) into README.md between the efficiency markers."""
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
table = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / "out" / "efficiency.md").read_text(encoding="utf-8").strip()
readme = root / "README.md"
text = readme.read_text(encoding="utf-8")
begin, end = "<!-- efficiency:begin -->", "<!-- efficiency:end -->"
if begin not in text:
    raise SystemExit("README.md has no efficiency markers")
head, rest = text.split(begin, 1)
_, tail = rest.split(end, 1)
readme.write_text(head + begin + "\n" + table + "\n" + end + tail, encoding="utf-8", newline="\n")
print("README.md updated")

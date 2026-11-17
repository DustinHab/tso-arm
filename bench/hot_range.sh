#!/bin/sh
# Lines of an annotated block (bench/hot_annotate.sh) between two host offsets (hex), with their sample counts.
#   bench/hot_range.sh RIP FROM TO
cd "$(dirname "$0")/.."
awk -v from="$2" -v to="$3" '
  function hex(s,   i, c, v) { v = 0; s = tolower(s); for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c } return v }
  { o = $2; sub(":", "", o); if (hex(o) >= hex(from) && hex(o) <= hex(to)) print }' out/hot-$1.txt

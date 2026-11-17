#!/bin/sh
# Escalated ranges of a profile that start inside [FROM, TO) (hex), and the total.
#   tools/prof_count.sh PROFILE FROM TO
awk -v from="$2" -v to="$3" '
  function hex(s,   i, c, v) { v = 0; s = tolower(s); for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c } return v }
  $1 == "esc" { total++; s = hex($2); if (s >= hex(from) && s < hex(to)) { n++; list = list " " $2 } }
  $1 == "fallback" { fb = 1 }
  END { printf "%d of %d escalated ranges in %s-%s%s\n%s\n", n, total, from, to, fb ? " (fallback)" : "", list }' "$1"

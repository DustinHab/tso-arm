#!/bin/sh
# Test machine: lines of a translated function in a workload's generated C that match a pattern (default: rep string
# instructions and guest calls), with the function's first lines.
#   aot/inspect_fn.sh WORKLOAD FUNCTION [PATTERN]
cd "$(dirname "$0")/.."
w=$1
f=$2
pat=${3:-rep|stos|movs|guest_call|aot_dispatch|memset|memcpy}
awk -v f="$f" '
    $0 ~ "^[a-z].* [fo]_" f "\\(" { on = 1; n = 0; print NR ": " $0; next }
    on && /^}/ { on = 0; print NR ": }"; next }
    on { n++; if (n <= 6) print NR ": " $0 }
' out/aot/$w.c | head -n 20
echo "--- matching"
awk -v f="$f" '
    $0 ~ "^[a-z].* f_" f "\\(" { on = 1; next }
    on && /^}/ { on = 0 }
    on { print NR ": " $0 }
' out/aot/$w.c | grep -E -i "$pat" | head -n 40

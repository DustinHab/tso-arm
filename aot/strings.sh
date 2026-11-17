#!/bin/sh
# Test machine: pigz with glibc's memmove and memset translated, used only by translated code (internal) or routed for
# every caller including FEX's code; median of 3 runs each under the page protocol with a profile, output checked.
#   aot/strings.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
for mode in internal routed; do
    if [ $mode = internal ]; then STRINGS=--internal sh aot/pigz.sh >/dev/null 2>&1; else STRINGS=" " sh aot/pigz.sh >/dev/null 2>&1; fi
    printf '%-9s routed: %s\n' $mode "$(grep -o '"[A-Za-z_0-9]*"},' out/aot/pigz.c | grep -c mem)"
    CONFIGS="native aot" ROUNDS=3 FEXENV="FEX_MULTIBLOCK=0" sh bench/efficiency.sh pigz >/dev/null 2>&1
    grep 'ahead of time' out/efficiency.md
done

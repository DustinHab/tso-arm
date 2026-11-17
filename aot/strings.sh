#!/bin/sh
# Test machine: pigz with glibc's memmove and memset translated as units, used only by translated code (internal) or
# routed for every caller including FEX's code; best of 3 runs under the page protocol with a profile, output checked.
#   aot/strings.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
for mode in internal strings; do
    STRINGS=--$mode sh aot/pigz.sh >/dev/null 2>&1 || { echo "$mode: build failed"; continue; }
    printf '%-9s routed string functions: %s\n' $mode "$(grep -o '"[A-Za-z_0-9]*"},' out/aot/pigz.c | grep -c mem)"
    CONFIGS="native aot-off aot" ROUNDS=3 sh bench/efficiency.sh pigz >/dev/null 2>&1
    grep 'ahead of time' out/efficiency.md
done

#!/bin/sh
# Test machine: rebuilds the three translated libraries, counts the rep stos sites in each and checks every output
# without ordering and under the page protocol.
#   aot/rebuild_check.sh
cd "$(dirname "$0")/.."
for w in pigz xz zstd; do
    sh aot/$w.sh >/dev/null 2>&1 || { echo "$w: build failed"; sh aot/$w.sh 2>&1 | tail -n 5; exit 1; }
    printf '%s: %s gfill, %s ofill\n' $w "$(grep -c 'gfill(' out/aot/$w.c)" "$(grep -c 'ofill(' out/aot/$w.c)"
done
for w in pigz xz zstd; do
    for cfg in off protocol; do
        sh aot/try.sh $w $cfg 2>&1 | grep -E "^$w aot "
    done
done

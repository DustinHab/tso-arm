#!/bin/sh
# Test machine: builds the libraries of translated functions for all workloads and runs each once without ordering and
# once with the page protocol, output checked.
#   aot/all.sh
cd "$(dirname "$0")/.."
for w in ${*:-pigz xz zstd}; do
    sh aot/$w.sh >/tmp/aot-build-$w.txt 2>&1 || { echo "$w: build failed"; tail -n 5 /tmp/aot-build-$w.txt; continue; }
    grep -E 'error|warning: ' /tmp/aot-build-$w.txt | head -n 5
    for cfg in off protocol; do
        sh aot/try.sh $w $cfg | head -n 1
        grep -a 'not ours\|unreachable' /tmp/aot-err.txt | head -n 3
    done
done

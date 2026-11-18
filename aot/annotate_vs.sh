#!/bin/sh
# Test machine: the instructions of one function with their share of its samples, natively or translated (no
# ordering), from the profiles aot/vs_native.sh recorded (/tmp/vn-native.data, /tmp/vn-off.data). Only lines with at
# least MIN percent (default 0.15) and their neighbours.
#   aot/annotate_vs.sh native|off FUNCTION [MIN]
cfg=$1
f=$2
min=${3:-0.15}
perf annotate -i /tmp/vn-$cfg.data --stdio -s $f 2>/dev/null | grep -v '^ *$' | awk -F: -v m=$min '
    { line[NR] = $0; p[NR] = $1 + 0 }
    END { for (i = 1; i <= NR; i++) if (p[i] >= m || p[i - 1] >= m || p[i + 1] >= m) print line[i] }' | head -n 160

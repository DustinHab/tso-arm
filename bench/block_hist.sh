#!/bin/sh
# Instruction histogram of a dumped block (bench/dump_block.sh), views and nopass side by side.
#   bench/block_hist.sh RIP [N]
cd "$(dirname "$0")/.."
for c in views nopass; do
    printf '%-7s' $c
    awk '{print $1}' out/block-$1-$c.s | sort | uniq -c | sort -rn | head -n ${2:-14} | awk '{printf " %s:%s", $2, $1}'
    echo
done

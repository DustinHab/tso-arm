#!/bin/sh
# Test machine: which of the guest functions FEX compiles at a workload's start-up (bench/startup_blocks.sh) the
# translator can take as they are: each of the top N tried alone, with its blocks and the translator's error.
#   aot/startup_liftable.sh [WORKLOAD] [N] [INPUT]
cd "$(dirname "$0")/.."
w=${1:-xz}
n=${2:-60}
sh bench/startup_blocks.sh $w ${3:-empty} | sed -n "2,$((n + 1))p" >/tmp/sl-top.txt
ok=0
okb=0
all=0
while read blocks pct pc name; do
    all=$((all + blocks))
    if err=$(python3 aot/lift.py build/x86/$w /tmp/sl-one.c $name 2>&1 >/dev/null); then
        ok=$((ok + 1))
        okb=$((okb + blocks))
        printf '  ok    %5d  %s\n' $blocks $name
    else
        printf '  fail  %5d  %-36s %s\n' $blocks $name "$(echo "$err" | tail -n 1 | cut -c1-110)"
    fi
done </tmp/sl-top.txt
echo "liftable: $ok functions, $okb of $all blocks"

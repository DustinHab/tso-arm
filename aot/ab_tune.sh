#!/bin/sh
# Test machine: the translated libraries built with clang -O2 against -O2 tuned for the Cortex-A76, all three
# workloads (aot/ab_cycles.sh, without ordering), log in out/ab-tune.log.
#   aot/ab_tune.sh [TUNED_FLAGS]
cd "$(dirname "$0")/.."
t=${1:--O2 -mtune=cortex-a76}
for w in pigz xz zstd; do
    sh aot/ab_cycles.sh $w 5 "CFLAGS=-O2" "CFLAGS=$t"
done >out/ab-tune.log 2>&1

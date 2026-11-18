#!/bin/sh
# Test machine: the library with the functions chosen by hand (aot/WORKLOAD.sh) against the one aot/auto.sh chose,
# for the three workloads under the page protocol (aot/ab_env.sh, six runs each, alternating). Log out/auto-vs-hand.log.
#   aot/auto_vs_hand.sh
cd "$(dirname "$0")/.."
for w in pigz xz zstd; do
    echo "== $w"
    sh aot/ab_env.sh $w 6 - "TSO_AOT=$PWD/out/aot/${w}_auto.so"
done >out/auto-vs-hand.log 2>&1

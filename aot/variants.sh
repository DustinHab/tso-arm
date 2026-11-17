#!/bin/sh
# Test machine: a workload under the page protocol with its translated functions in a few settings, to narrow down
# a failure: plain variants first, ordered from the start, and each function alone.
#   aot/variants.sh WORKLOAD
cd "$(dirname "$0")/.."
w=$1
for i in 1 2; do
    printf '%-36s ' "all, plain first"
    sh aot/try.sh $w protocol | head -n 1
done
printf '%-36s ' "all, ordered from the start"
AOT_ENV="TSO_AOT_ORDERED=1" sh aot/try.sh $w protocol | head -n 1
for f in $(grep -o '"[A-Za-z_0-9]*"},' out/aot/$w.c | tr -d '"},'); do
    printf '%-36s ' $f
    AOT_ENV="TSO_AOT_ONLY=$f" sh aot/try.sh $w protocol | head -n 1
done

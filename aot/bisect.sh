#!/bin/sh
# Test machine: runs a workload with each translated function routed alone (TSO_AOT_ONLY), to find one that
# translates wrongly.
#   aot/bisect.sh WORKLOAD [CONFIG]
cd "$(dirname "$0")/.."
w=$1
for f in $(grep -o '"[A-Za-z_0-9]*"},' out/aot/$w.c | tr -d '"},'); do
    printf '%-36s ' $f
    AOT_ENV="TSO_AOT_ONLY=$f" sh aot/try.sh $w ${2:-off} | head -n 1
done

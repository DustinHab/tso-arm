#!/bin/sh
# Where cycles go, native against FEX without ordering: stalls, loads/stores, cache traffic, branches.
#   bench/stalls.sh [workload]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
w=${1:-xz}
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
EV1=cycles:u,stalled-cycles-frontend:u,stalled-cycles-backend:u,instructions:u,br_mis_pred:u,br_indirect_spec:u
EV2=ld_spec:u,st_spec:u,l1d_cache:u,l1d_cache_refill:u,l2d_cache_refill:u,br_return_spec:u
for cfg in native fex; do
    case $cfg in
    native) cmd="$N/$w" vars="" ;;
    fex) cmd="$HOME/opt/fex/bin/FEX $X/$w" vars="FEX_TSOENABLED=0" ;;
    esac
    for EV in $EV1 $EV2; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        printf '%-7s' $cfg
        env $vars perf stat -x, -e $EV $cmd $args 2>&1 >/dev/null | awk -F, '{ n = $3; sub(":u", "", n); printf " %s %.3f", n, $1 / 1e9 } END { printf "\n" }'
    done
done

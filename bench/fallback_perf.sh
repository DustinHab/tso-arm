#!/bin/sh
# User and kernel cycles of a workload under FEX's full TSO and in the fallback (from the start), to locate the
# fallback's extra cost.
#   bench/fallback_perf.sh [workload]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=${1:-zstd}
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
P=/tmp/tso-fallback.prof
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in full fallback fallback-plainstack; do
    case $cfg in
    full) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex/bin/FEX ;;
    fallback) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$P FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex-views/bin/FEX ;;
    fallback-plainstack) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$P TSO_VIEWS_FALLBACK_STACK=plain FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex-views/bin/FEX ;;
    esac
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
    echo fallback >$P
    printf '%-20s' $cfg
    env $vars perf stat -x, -e instructions:u,cycles:u,cycles:k,page-faults $bin $cmd 2>&1 >/dev/null |
        awk -F, '{ printf " %s %.3f G", $3, $1 / 1e9 } END { printf "\n" }'
done

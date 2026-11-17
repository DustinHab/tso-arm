#!/bin/sh
# zstd in the fallback from the start (TSO_VIEWS_BUDGET=1 with an empty profile... simpler: a profile that says
# fallback), with and without ordered stack accesses, against FEX's full TSO. Best of 3, wall time.
#   bench/fallback_cost.sh [workload]
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
echo fallback >$P
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in full fallback fallback-plainstack; do
    case $cfg in
    full) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex/bin/FEX ;;
    fallback) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$P FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex-views/bin/FEX ;;
    fallback-plainstack) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$P TSO_VIEWS_FALLBACK_STACK=plain FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex-views/bin/FEX ;;
    esac
    best=999
    for r in 1 2 3; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        echo fallback >$P
        /usr/bin/time -f '%e' -o /tmp/fc.time env $vars $bin $cmd >/dev/null 2>/dev/null
        t=$(cat /tmp/fc.time)
        best=$(echo "$t $best" | awk '{print ($1 < $2) ? $1 : $2}')
    done
    printf '%-20s %s s\n' $cfg $best
done

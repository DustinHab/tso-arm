#!/bin/sh
# Instructions and cycles (user mode) of one workload under FEX with and without the view rewriting pass.
#   bench/perf_views.sh [xz|zstd|pigz]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=${1:-xz}
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
EV=instructions:u,cycles:u,L1-dcache-load-misses:u,dTLB-load-misses:u,branch-misses:u
for cfg in off views-id-nopass views-off; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0" bin=$HOME/opt/fex/bin/FEX ;;
    views-id-nopass) vars="TSO_VIEWS=1 TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 FEX_TSOENABLED=0" bin=$HOME/opt/fex-views/bin/FEX ;;
    views-off) vars="TSO_VIEWS=1 FEX_TSOENABLED=0" bin=$HOME/opt/fex-views/bin/FEX ;;
    esac
    echo "== $cfg"
    env $vars perf stat -x, -e $EV $bin $cmd 2>&1 >/dev/null | awk -F, '{ printf "  %-28s %15s\n", $3, $1 }'
done

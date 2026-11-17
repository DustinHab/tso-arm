#!/bin/sh
# Where the base cost of the views goes: instructions and cycles (user mode) of one workload, everything plain
# (TSO off), from upstream FEX to the full view machinery, one piece added at a time.
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
EV=instructions:u,cycles:u,L1-dcache-load-misses:u,dTLB-load-misses:u
V="TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 FEX_TSOENABLED=0"
for cfg in off shared shared+exact arith arith+exact views+exact; do
    bin=$HOME/opt/fex-views/bin/FEX
    case $cfg in
    off) vars="FEX_TSOENABLED=0" bin=$HOME/opt/fex/bin/FEX ;;
    # shared memory and x24 taken from the register allocator, no rewriting
    shared) vars="$V TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 TSO_VIEWS_NOEXACT=1" ;;
    shared+exact) vars="$V TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1" ;;
    # plus the address arithmetic, with view base 0
    arith) vars="$V TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOEXACT=1" ;;
    arith+exact) vars="$V TSO_VIEWS_IDENTITY=1" ;;
    # the real views
    views+exact) vars="$V" ;;
    esac
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
    printf '%-14s' "$cfg"
    env $vars perf stat -x, -e $EV $bin $cmd 2>&1 >/dev/null | awk -F, '$3 ~ /instructions|cycles/ { printf " %s %6.2f G", $3, $1 / 1e9 } END { printf "\n" }'
done

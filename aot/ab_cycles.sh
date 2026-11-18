#!/bin/sh
# Test machine: A/B of two builds of a workload's translated library that differ by an environment setting of its
# build script (aot/WORKLOAD.sh, e.g. ORDERED="--ordered crc32_z"): user cycles and wall time, N runs each (default
# 5) alternating, fixed clock; medians, and the cycles of the hottest functions. CFG=off (default): without
# ordering; CFG=protocol: page protocol with a profile of each build's own.
#   aot/ab_cycles.sh WORKLOAD [N] [SETTING_A] [SETTING_B]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=$1
n=${2:-5}
A=${3:-ORDERED=}
B=${4:-ORDERED=--ordered crc32_z}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
vars() {
    if [ "${CFG:-off}" = protocol ]; then
        echo "TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/ab-$1.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=/tmp/ab-$1.so"
    else
        echo "FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=/tmp/ab-$1.so"
    fi
}
for v in A B; do
    eval "s=\$$v"
    env "$s" sh aot/$w.sh >/dev/null 2>&1 || { echo "build $s failed"; exit 1; }
    cp out/aot/$w.so /tmp/ab-$v.so
    rm -f /tmp/ab-$v.prof
    [ "${CFG:-off}" = protocol ] && env $(vars $v) $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
done
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
rm -f /tmp/ab-A.txt /tmp/ab-B.txt
for i in $(seq $n); do
    for v in A B; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
        s=$(date +%s%N)
        env $(vars $v) perf stat -x, -e cycles:u -o /tmp/ab-stat.txt \
            $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
        e=$(date +%s%N)
        echo "$(awk -F, '/cycles/ { print $1 }' /tmp/ab-stat.txt) $(( (e - s) / 1000000 ))" >>/tmp/ab-$v.txt
    done
done
for v in A B; do
    eval "s=\$$v"
    printf '%-16s user cycles %s G, wall %s ms (medians of %d)\n' "$s" \
        "$(sort -n /tmp/ab-$v.txt | awk '{ c[NR] = $1 } END { printf "%.3f", c[int((NR + 1) / 2)] / 1e9 }')" \
        "$(awk '{ print $2 }' /tmp/ab-$v.txt | sort -n | awk '{ c[NR] = $1 } END { print c[int((NR + 1) / 2)] }')" $n
done
for v in A B; do
    env $(vars $v) perf record -q -e cycles:u -o /tmp/ab-$v.data \
        $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    echo "== $v: hottest functions (G cycles)"
    total=$(perf report -i /tmp/ab-$v.data --stdio 2>/dev/null | awk '/Event count/ { print $NF }')
    perf report -i /tmp/ab-$v.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 6 |
        awk -v t=$total '{ p = $1; sub(/%/, "", p); printf "  %6.3f  %s\n", p * t / 1e11, $NF }'
done
sh aot/$w.sh >/dev/null 2>&1

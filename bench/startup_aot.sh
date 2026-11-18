#!/bin/sh
# Test machine: the fixed cost per process in the configurations the efficiency table measures with translated
# functions (a workload on an empty input, median of 15, fixed clock), with and without FEX's telemetry file, and
# where the cycles of 20 such runs go (perf: binary and function, user and kernel).
#   bench/startup_aot.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
N=$PWD/build/arm64
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
lib=$PWD/out/aot/$w.so
prof=$HOME/.cache/tso-arm/$w-aot.prof
F=$HOME/opt/fex-views/bin/FEX
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib"
O="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib"
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in ${CONFIGS-native aot-off aot-off-notelemetry aot aot-notelemetry aot-nolib}; do
    case $cfg in
    native) cmd="$N/$w" vars="X=1" ;;
    aot-off) cmd="$F $X/$w" vars="$O" ;;
    aot-off-notelemetry) cmd="$F $X/$w" vars="$O FEX_DISABLETELEMETRY=1" ;;
    aot) cmd="$F $X/$w" vars="$P" ;;
    aot-notelemetry) cmd="$F $X/$w" vars="$P FEX_DISABLETELEMETRY=1" ;;
    aot-nolib) cmd="$F $X/$w" vars="$(echo $P | sed 's/TSO_AOT=[^ ]*//')" ;;
    esac
    t=""
    for i in $(seq 15); do
        s=$(date +%s%N)
        env $vars $cmd $args >/dev/null 2>&1
        e=$(date +%s%N)
        t="$t $(( (e - s) / 10000 ))"
    done
    med=$(echo $t | tr ' ' '\n' | sort -n | sed -n 8p)
    printf '%-22s %6.2f ms\n' $cfg "$(echo "$med / 100" | bc -l)"
done
rm -f /tmp/sa.data
cat >/tmp/sa-loop.sh <<EOF
for i in \$(seq 20); do env $P $F $X/$w $args >/dev/null 2>&1; done
EOF
perf record -q -e cycles -o /tmp/sa.data sh /tmp/sa-loop.sh >/dev/null 2>&1
echo "== cycles of 20 runs (aot), by command and binary"
perf report -i /tmp/sa.data --sort comm,dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 12
echo "== by function"
perf report -i /tmp/sa.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 40 | cut -c1-140

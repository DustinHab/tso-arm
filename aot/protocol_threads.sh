#!/bin/sh
# Test machine: user cycles per thread (and per binary in each thread) of a workload with its translated functions,
# without ordering and under the page protocol with a profile.
#   aot/protocol_threads.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/pt-$w.prof
rm -f $prof
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib \
    $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in off protocol; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    esac
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
    env $vars perf record -q -e cycles:u -o /tmp/pt-$cfg.data $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    total=$(perf report -i /tmp/pt-$cfg.data --stdio 2>/dev/null | awk '/Event count/ { print $NF }')
    echo "== $cfg: $(echo "$total / 1000000000" | bc -l | cut -c1-5) G cycles"
    perf report -i /tmp/pt-$cfg.data --sort pid,dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 14 |
        awk -v t=$total '{ p = $1; sub(/%/, "", p); printf "  %6.3f G  %s %s %s\n", p * t / 1e11, $2, $3, $4 }'
done

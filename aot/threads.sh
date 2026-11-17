#!/bin/sh
# Test machine: user cycles per thread of a workload, natively and under FEX (without ordering, without and with its
# translated functions), to see whether a serial thread bounds the wall time.
#   aot/threads.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-zstd}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in native fex aot; do
    case $cfg in
    native) cmd="$N/$w" vars="" ;;
    fex) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="FEX_TSOENABLED=0" ;;
    aot) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="FEX_TSOENABLED=0 TSO_AOT=$PWD/out/aot/$w.so" ;;
    esac
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
    s=$(date +%s.%N)
    env $vars perf record -q -e cycles:u -o /tmp/thr.data $cmd $args >/dev/null 2>&1
    e=$(date +%s.%N)
    total=$(perf report -i /tmp/thr.data --stdio -F overhead,sample 2>/dev/null | awk '/^#.*Samples:/ { print }' | head -1)
    printf '%-7s wall %.3f s; share of user cycles per thread:' $cfg "$(echo "$e - $s" | bc)"
    perf report -i /tmp/thr.data --sort tid --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | awk '{ printf " %s", $1 }' | head -c 300
    echo
    perf report -i /tmp/thr.data --stdio --header-only 2>/dev/null | grep -i 'sample' | head -1
done

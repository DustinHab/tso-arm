#!/bin/sh
# Test machine: user cycles and instructions of a workload natively and under FEX without ordering, without and with
# its translated functions (one run each, fixed clock).
#   aot/cycles.sh [WORKLOAD]
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
    env $vars perf stat -x, -e cycles:u,instructions:u,task-clock -o /tmp/cyc.txt $cmd $args >/dev/null 2>&1
    printf '%-7s %s\n' $cfg "$(awk -F, '/cycles|instructions/ { printf "%s %.3f G  ", $3, $1 / 1e9 } /task-clock/ { printf "cpu %.3f s", $1 / 1e3 }' /tmp/cyc.txt)"
done

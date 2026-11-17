#!/bin/sh
# User-mode instructions and cycles: native Arm build against the x86-64 build under FEX without ordering.
#   bench/native_vs_fex.sh [workload ...]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
EV=instructions:u,cycles:u,branch-misses:u,L1-icache-load-misses:u
for w in ${*:-pigz xz zstd}; do
    case $w in
    zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) args="-n -p 4 -c $C/corpus.tar" ;;
    xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
    for cfg in native fex-off; do
        case $cfg in
        native) cmd="$N/$w" vars="" ;;
        fex-off) cmd="$HOME/opt/fex/bin/FEX $X/$w" vars="FEX_TSOENABLED=0" ;;
        esac
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        printf '%-5s %-8s' $w $cfg
        env $vars perf stat -x, -e $EV $cmd $args 2>&1 >/dev/null | awk -F, '{ printf " %s %.3f G", $3, $1 / 1e9 } END { printf "\n" }'
    done
done

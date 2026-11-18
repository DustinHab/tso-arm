#!/bin/sh
# Test machine: user and kernel cycles, task clock, page faults and context switches of a workload with its
# translated functions, without ordering and under the page protocol (with a profile), fixed clock, median wall of 5.
#   aot/protocol_stat.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/ps-$w.prof
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
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
    sudo env $vars HOME=$HOME perf stat -x, -e task-clock,cycles:u,cycles:k,page-faults,context-switches,cpu-migrations \
        -o /tmp/ps-$cfg.txt $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    printf '%-9s %s\n' $cfg "$(awk -F, 'NF > 3 { v = $1; n = $3; if (n ~ /cycles/) printf "%s %.3f G  ", n, v / 1e9; else if (n ~ /task-clock/) printf "cpu %.3f s  ", v / 1e3; else printf "%s %d  ", n, v }' /tmp/ps-$cfg.txt)"
done

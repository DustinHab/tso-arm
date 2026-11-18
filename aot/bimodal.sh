#!/bin/sh
# Test machine: a workload with its translated functions under the page protocol (profile from one run before),
# N runs (default 12) at a fixed clock, each with its wall, user and system time and the protocol's counters, to see
# what the slow runs have in common.
#   aot/bimodal.sh [WORKLOAD] [N]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
n=${2:-12}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/bm-$w.prof
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib FEX_DISABLETELEMETRY=1"
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/bm-out' EXIT
rm -f $prof
env $P $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
sh tools/freq.sh fix 1800000 >/dev/null
for i in $(seq $n); do
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
    rm -f /tmp/bm-stats.txt
    s=$(date +%s%N)
    env $P TSO_VIEWS_STATS=/tmp/bm-stats.txt ${EXTRA:-} /usr/bin/time -f '%U %S %c %w' -o /tmp/bm-time $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/shm/bm-out 2>/dev/null
    e=$(date +%s%N)
    st=$(tr '\n' ' ' </tmp/bm-stats.txt | sed 's/tso-arm: //g; s/completed in the handler/handled/; s/ranges mapped into a view on first use/lazy-ranges/; s/pages moved with their chunk/chunk-pages/')
    printf '%5d ms  usr/sys/ivcsw/vcsw %s | %s\n' $(( (e - s) / 1000000 )) "$(cat /tmp/bm-time)" "$st"
done

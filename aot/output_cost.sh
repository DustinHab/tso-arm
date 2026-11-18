#!/bin/sh
# Test machine: what writing the output costs a workload with its translated functions, without ordering and under
# the page protocol with a profile: output to /dev/null against a file in /dev/shm (as bench/efficiency.sh writes
# it), wall time median of 5, fixed clock, and the system time and page faults of one run each.
#   aot/output_cost.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/oc2-$w.prof
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib FEX_DISABLETELEMETRY=1"
O="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib FEX_DISABLETELEMETRY=1"
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/oc2-out' EXIT
rm -f $prof
env $P $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done; }
for cfg in native off protocol; do
    case $cfg in
    native) cmd="$N/$w" vars="X=1" ;;
    off) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="$O" ;;
    protocol) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="$P" ;;
    esac
    for out in /dev/null /dev/shm/oc2-out; do
        t=""
        for i in 1 2 3 4 5; do
            cool
            s=$(date +%s%N)
            env $vars $cmd $args >$out 2>/dev/null
            e=$(date +%s%N)
            t="$t $(( (e - s) / 1000000 ))"
        done
        cool
        env $vars /usr/bin/time -f '%S s sys, %R minor faults' -o /tmp/oc2-time $cmd $args >$out 2>/dev/null
        printf '%-9s > %-16s %5d ms  (%s)  %s\n' $cfg $out "$(echo $t | tr ' ' '\n' | sort -n | sed -n 3p)" "$(echo $t)" "$(cat /tmp/oc2-time)"
    done
done
ls -la /dev/shm/oc2-out | awk '{ print "output", $5, "bytes" }'

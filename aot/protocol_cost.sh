#!/bin/sh
# Test machine: what the page protocol costs a workload whose hot functions are translated ahead of time: the same
# translation without ordering against the protocol with a profile. Wall, user and system time (median of 5 runs),
# the start-up on an empty input, and the protocol's own counters.
#   aot/protocol_cost.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" empty="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" empty="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" empty="-T4 -6 -c /dev/null" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/pc-$w.prof
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done; }
rm -f $prof
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib \
    $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
for cfg in off protocol; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    esac
    rows=""
    for i in 1 2 3 4 5; do
        cool
        s=$(date +%s%N)
        env $vars /usr/bin/time -f '%U %S' -o /tmp/pc-time.txt $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
        e=$(date +%s%N)
        rows="$rows$(( (e - s) / 1000000 )) $(cat /tmp/pc-time.txt)\n"
    done
    med=$(printf "$rows" | sort -n | sed -n 3p)
    st=""
    for i in 1 2 3 4 5; do
        s=$(date +%s%N)
        env $vars $HOME/opt/fex-views/bin/FEX $X/$w $empty >/dev/null 2>&1
        e=$(date +%s%N)
        st="$st $(( (e - s) / 100000 ))"
    done
    stmed=$(echo $st | tr ' ' '\n' | sort -n | sed -n 3p)
    printf '%-9s wall/user/sys (ms, s, s): %s   start-up %s ms\n' $cfg "$med" "$(echo "$stmed / 10" | bc -l | cut -c1-5)"
done
rm -f /tmp/pc-stats.txt
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof TSO_VIEWS_STATS=/tmp/pc-stats.txt FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 \
    FEX_MULTIBLOCK=0 TSO_AOT=$lib $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
cat /tmp/pc-stats.txt
echo "profile: $(grep -c esc $prof) escalated ranges$(grep -q fallback $prof && echo ', fallback')"

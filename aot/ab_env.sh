#!/bin/sh
# Test machine: A/B of protocol settings for a workload with its translated functions (page protocol with a profile
# of each setting's own, learned in a run before): N runs each (default 6), alternating, fixed clock; best and median
# wall time, median user cycles, output checked.
#   aot/ab_env.sh WORKLOAD [N] "SETTINGS_A" "SETTINGS_B" ...     ("-" for none)
cd "$(dirname "$0")/.."
export LC_ALL=C
w=$1
n=${2:-6}
shift 2
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=$PWD/out/aot/$w.so"
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/abe-out' EXIT
k=0
for s in "$@"; do
    k=$((k + 1))
    rm -f /tmp/abe-$k.prof /tmp/abe-$k.txt
    env $P TSO_VIEWS_PROFILE=/tmp/abe-$k.prof $( [ "$s" = - ] || echo "$s") $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
done
sh tools/freq.sh fix 1800000 >/dev/null
for i in $(seq $n); do
    k=0
    for s in "$@"; do
        k=$((k + 1))
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
        t0=$(date +%s%N)
        env $P TSO_VIEWS_PROFILE=/tmp/abe-$k.prof $( [ "$s" = - ] || echo "$s") perf stat -x, -e cycles:u -o /tmp/abe-stat.txt \
            $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/shm/abe-out 2>/dev/null
        t1=$(date +%s%N)
        ok=ok
        [ "$(md5sum </dev/shm/abe-out | cut -c1-8)" != "$want" ] && ok=WRONG
        echo "$(( (t1 - t0) / 1000000 )) $(awk -F, '/cycles/ { print $1 }' /tmp/abe-stat.txt) $ok" >>/tmp/abe-$k.txt
    done
done
k=0
for s in "$@"; do
    k=$((k + 1))
    printf '%-44s best %5d ms, median %5d ms, user %.3f G  %s  (%s)\n' "$s" \
        "$(sort -n /tmp/abe-$k.txt | head -n 1 | cut -d' ' -f1)" \
        "$(sort -n /tmp/abe-$k.txt | awk '{ c[NR] = $1 } END { print c[int((NR + 1) / 2)] }')" \
        "$(awk '{ print $2 }' /tmp/abe-$k.txt | sort -n | awk '{ c[NR] = $1 } END { printf "%.3f", c[int((NR + 1) / 2)] / 1e9 }')" \
        "$(grep -q WRONG /tmp/abe-$k.txt && echo WRONG || echo ok)" "$(cut -d' ' -f1 /tmp/abe-$k.txt | tr '\n' ' ')"
    grep -q fallback /tmp/abe-$k.prof && echo "    (profile: fallback)"
done

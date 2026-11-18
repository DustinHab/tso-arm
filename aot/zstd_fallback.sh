#!/bin/sh
# Test machine: zstd with its translated functions under the page protocol, with the fallback to full ordering (as
# measured so far) and without it (TSO_VIEWS_BUDGET=0), each with a profile of its own from a run before; median wall
# time of 5, output checked, and the protocol's counters of one run.
#   aot/zstd_fallback.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
C=$PWD/build
args="-T4 -3 -f -q -c $C/corpus.tar"
want=$(grep "^zstd " build/expected.md5 | cut -d' ' -f2)
trap 'sh tools/freq.sh restore >/dev/null' EXIT
for mode in ${MODES:-fallback nofallback nofallback-nochunk}; do
    extra=""
    [ $mode = nofallback ] && extra="TSO_VIEWS_BUDGET=0"
    [ $mode = nofallback-nochunk ] && extra="TSO_VIEWS_BUDGET=0 TSO_VIEWS_CHUNK=0"
    [ $mode = nofallback-migrate ] && extra="TSO_VIEWS_BUDGET=0 TSO_VIEWS_MIGRATE=1"
    [ $mode = migrate ] && extra="TSO_VIEWS_MIGRATE=1"
    vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/zf-$mode.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/zstd.so $extra"
    rm -f /tmp/zf-$mode.prof
    env $vars $HOME/opt/fex-views/bin/FEX $X/zstd $args >/dev/null 2>&1
    sh tools/freq.sh fix 1800000 >/dev/null
    t=""
    ok=ok
    for i in 1 2 3 4 5; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
        s=$(date +%s%N)
        env $vars $HOME/opt/fex-views/bin/FEX $X/zstd $args >/dev/shm/zf-out 2>/dev/null
        e=$(date +%s%N)
        [ "$(md5sum </dev/shm/zf-out | cut -c1-8)" != "$want" ] && ok=WRONG
        t="$t $(( (e - s) / 1000000 ))"
    done
    sh tools/freq.sh restore >/dev/null
    med=$(echo $t | tr ' ' '\n' | sort -n | sed -n 3p)
    printf '%-11s %5d ms %s  (%s)\n' $mode $med $ok "$(echo $t)"
    rm -f /tmp/zf-stats.txt
    env $vars TSO_VIEWS_STATS=/tmp/zf-stats.txt $HOME/opt/fex-views/bin/FEX $X/zstd $args >/dev/null 2>&1
    cat /tmp/zf-stats.txt 2>/dev/null | sed 's/^/    /'
done
rm -f /dev/shm/zf-out

#!/bin/sh
# Test machine: guest mappings put into every thread's views at once (TSO_VIEWS_EAGER=1, as before) against each
# thread's views getting a range at its first access: median wall time of 5 runs under the page protocol with a
# profile, translated functions on, output checked; and the mremap and mprotect calls of one run.
#   aot/lazy_views.sh [WORKLOAD ...]
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
C=$PWD/build
trap 'sh tools/freq.sh restore >/dev/null' EXIT
for w in ${*:-xz pigz zstd}; do
    case $w in
    zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) args="-n -p 4 -c $C/corpus.tar" ;;
    xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    for mode in eager lazy; do
        extra=""
        [ $mode = eager ] && extra="TSO_VIEWS_EAGER=1"
        vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/lv-$w-$mode.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so $extra"
        rm -f /tmp/lv-$w-$mode.prof
        env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
        sh tools/freq.sh fix 1800000 >/dev/null
        t=""
        ok=ok
        for i in 1 2 3 4 5; do
            while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
            s=$(date +%s%N)
            env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/shm/lv-out 2>/dev/null
            e=$(date +%s%N)
            [ "$(md5sum </dev/shm/lv-out | cut -c1-8)" != "$want" ] && ok=WRONG
            t="$t $(( (e - s) / 1000000 ))"
        done
        sh tools/freq.sh restore >/dev/null
        med=$(echo $t | tr ' ' '\n' | sort -n | sed -n 3p)
        env $vars strace -f -c -o /tmp/lv-strace.txt $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
        calls=$(awk '$NF == "mremap" || $NF == "mprotect" || $NF == "mmap" { printf "%s %s  ", $NF, $(NF - 1) }' /tmp/lv-strace.txt)
        printf '%-5s %-6s %5d ms  %s   %s\n' $w $mode $med $ok "$calls"
    done
done
rm -f /dev/shm/lv-out

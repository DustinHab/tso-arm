#!/bin/sh
# Test machine: a workload's library built as usual and with some functions starting in their ordered variant
# (ORDERED="--ordered NAME..."), each run 5 times under the page protocol with a profile of its own; median wall
# time, output checked.
#   aot/ordered_cmp.sh WORKLOAD "--ordered NAME..."
cd "$(dirname "$0")/.."
export LC_ALL=C
w=$1
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
trap 'sh tools/freq.sh restore >/dev/null' EXIT
for variant in plain "$2"; do
    ORDERED="$( [ "$variant" = plain ] || echo "$variant")" sh aot/$w.sh >/dev/null 2>&1 || { echo "build failed"; exit 1; }
    vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/oc-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so"
    rm -f /tmp/oc-$w.prof
    env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    sh tools/freq.sh fix 1800000 >/dev/null
    t=""
    ok=ok
    for i in 1 2 3 4 5; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
        s=$(date +%s%N)
        env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/shm/oc-out 2>/dev/null
        e=$(date +%s%N)
        [ "$(md5sum </dev/shm/oc-out | cut -c1-8)" != "$want" ] && ok=WRONG
        t="$t $(( (e - s) / 1000000 ))"
    done
    sh tools/freq.sh restore >/dev/null
    printf '%-28s %5d ms %s  (%s)\n' "$variant" "$(echo $t | tr ' ' '\n' | sort -n | sed -n 3p)" $ok "$(echo $t)"
done
sh aot/$w.sh >/dev/null 2>&1
rm -f /dev/shm/oc-out

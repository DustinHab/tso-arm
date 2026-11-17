#!/bin/sh
# Runs the static x86-64 workloads (study/build_static.sh) under the page-state client.
# Results: study/results/NAME.txt, plain-instruction lists: build/lists/NAME.plain
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/run_real.sh [NAME ...]
SRC=$(cd "$(dirname "$0")" && pwd)
R=$(dirname "$SRC")
B=$HOME/study/build
D=$HOME/study/data
X=$R/build/x86
DR=/opt/dynamorio/current
T=/tmp/pagestate
mkdir -p $D $SRC/results $R/build/lists $T
cmake -S $SRC -B $B -G Ninja -DDynamoRIO_DIR=$DR/cmake -DCMAKE_BUILD_TYPE=Release >$B/cmake.log 2>&1 || { tail -30 $B/cmake.log; exit 1; }
ninja -C $B >$B/ninja.log 2>&1 || { tail -40 $B/ninja.log; exit 1; }

if [ ! -f $D/corpus.tar ]; then
    tar cf - /usr/include /usr/share/doc 2>/dev/null | head -c 104857600 >$D/corpus.tar
    head -c 8388608 $D/corpus.tar >$D/corpus8.tar
fi
cp $D/corpus.tar $D/corpus8.tar $R/build/ 2>/dev/null || true

# run NAME BINARY ARGS...   (output of the program is discarded)
run() {
    name=$1
    case " ${SELECT:-all} " in *" all "* | *" $name "*) ;; *) return ;; esac
    shift
    app=$(basename $1)
    t0=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    t1=$(date +%s.%N)
    rm -f $T/r.* $T/l.*
    timeout 3600 $DR/bin64/drrun -c $B/libpagestate.so -out $T/r -list $T/l -- "$@" >/dev/null 2>&1
    rc=$?
    t2=$(date +%s.%N)
    res=$(ls -S $T/r.$app.*.txt 2>/dev/null | head -n 1)
    lst=$(ls -S $T/l.$app.*.plain 2>/dev/null | head -n 1)
    {
        cat "$res"
        printf 'command %s\nnative %.2f s   instrumented %.0f s   exit %d\n' "$*" "$(echo "$t1 - $t0" | bc)" \
            "$(echo "$t2 - $t1" | bc)" $rc
    } >$SRC/results/$name.txt
    [ -n "$lst" ] && sort "$lst" >$R/build/lists/$name.plain
    echo "== $name"
    cat $SRC/results/$name.txt
}

SELECT="$*"
run zstd $X/zstd -T4 -3 -f -q -c $D/corpus.tar
run pigz $X/pigz -p 4 -c $D/corpus.tar
run xz $X/xz -T4 -6 --block-size=2MiB -c $D/corpus8.tar
run 7zz $X/7zz b 1 -mmt4 -md20

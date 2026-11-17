#!/bin/sh
# Runs all workloads under the page-state client in both modes (views, global) and prints one compact table.
# Results: study/results/modes-NAME-MODE.txt, table: study/results/modes.txt
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/run_modes.sh [NAME ...]
SRC=$(cd "$(dirname "$0")" && pwd)
R=$(dirname "$SRC")
B=$HOME/study/build
D=$HOME/study/data
X=$R/build/x86
DR=/opt/dynamorio/current
T=/tmp/pagestate-modes
mkdir -p $SRC/results $T
cmake -S $SRC -B $B -G Ninja -DDynamoRIO_DIR=$DR/cmake -DCMAKE_BUILD_TYPE=Release >$B/cmake.log 2>&1 || { tail -30 $B/cmake.log; exit 1; }
ninja -C $B >$B/ninja.log 2>&1 || { tail -40 $B/ninja.log; exit 1; }
gcc -O2 -pthread -static -no-pie -o $B/patterns $SRC/work/patterns.c

cmd_of() {
    case $1 in
    zstd) echo "$X/zstd -T4 -3 -f -q -c $D/corpus.tar" ;;
    pigz) echo "$X/pigz -p 4 -c $D/corpus.tar" ;;
    xz) echo "$X/xz -T4 -6 --block-size=2MiB -c $D/corpus8.tar" ;;
    7zz) echo "$X/7zz b 1 -mmt4 -md20" ;;
    table | private | shared | queue) echo "$B/patterns $1" ;;
    esac
}

for name in ${*:-private table shared queue zstd pigz xz 7zz}; do
    for mode in views global; do
        rm -f $T/r.*
        timeout 5400 $DR/bin64/drrun -c $B/libpagestate.so -mode $mode -out $T/r -- $(cmd_of $name) >/dev/null 2>&1
        app=$(cmd_of $name | cut -d' ' -f1 | xargs basename)
        res=$(ls -S $T/r.$app.*.txt 2>/dev/null | head -n 1)
        cp "$res" $SRC/results/modes-$name-$mode.txt
        echo "== $name $mode"
        grep -E '^(mode|faults|store |vector store|load )' $SRC/results/modes-$name-$mode.txt
    done
done | tee $SRC/results/modes.txt

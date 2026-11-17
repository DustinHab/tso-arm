#!/bin/sh
# Runs workloads in 'check' mode at several tracking granularities. Results: study/results/check-NAME-SHIFT.txt
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/run_check.sh "12 16" zstd pigz xz
SRC=$(cd "$(dirname "$0")" && pwd)
R=$(dirname "$SRC")
B=$HOME/study/build-check
D=$HOME/study/data
X=$R/build/x86
DR=/opt/dynamorio/current
T=/tmp/pagestate-check
mkdir -p $SRC/results $T $R/build/lists
cmake -S $SRC -B $B -G Ninja -DDynamoRIO_DIR=$DR/cmake -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
ninja -C $B >$B/ninja.log 2>&1 || { tail -40 $B/ninja.log; exit 1; }
gcc -O2 -pthread -static -no-pie -o $B/patterns $SRC/work/patterns.c

cmd_of() {
    case $1 in
    zstd) echo "$X/zstd -T4 -3 -f -q -c $D/corpus.tar" ;;
    pigz) echo "$X/pigz -n -p 4 -c $D/corpus.tar" ;;
    xz) echo "$X/xz -T4 -6 --block-size=2MiB -c $D/corpus8.tar" ;;
    7zz) echo "$X/7zz b 1 -mmt4 -md20" ;;
    table | private | shared | queue) echo "$B/patterns $1" ;;
    esac
}

shifts=$1
shift
for name in "$@"; do
    for s in $shifts; do
        rm -f $T/r.* $T/l.*
        timeout 5400 $DR/bin64/drrun -c $B/libpagestate.so -mode check -page_shift $s -out $T/r -list $T/l -- \
            $(cmd_of $name) >/dev/null 2>&1
        app=$(cmd_of $name | cut -d' ' -f1 | xargs basename)
        cp "$(ls -S $T/r.$app.*.txt | head -n 1)" $SRC/results/check-$name-$s.txt
        lst=$(ls -S $T/l.$app.*.plain 2>/dev/null | head -n 1)
        [ -n "$lst" ] && sort "$lst" >$R/build/lists/$name-check-$s.plain
        echo "== $name check page_shift $s"
        grep -E '^(mode|faults|accesses of|store |vector store|load |vector load)' $SRC/results/check-$name-$s.txt
    done
done

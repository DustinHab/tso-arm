#!/bin/sh
# Runs workloads in 'check' mode for combinations of tracking granularity and collapse threshold.
# Results: study/results/check-NAME-SHIFT-COLLAPSE.txt, lists build/lists/NAME-check-SHIFT-COLLAPSE.plain
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/run_check.sh "12" "none c4 b20" zstd pigz xz
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

# policies: none, cN (collapse a chunk after N transitions), bR (brake at R transitions per million accesses)
policy_opts() {
    case $1 in
    none) echo "" ;;
    c*) echo "-collapse ${1#c}" ;;
    b*) echo "-brake ${1#b}" ;;
    esac
}

shifts=$1
collapses=$2
shift 2
for name in "$@"; do
    for s in $shifts; do
        for c in $collapses; do
            rm -f $T/r.* $T/l.*
            timeout 5400 $DR/bin64/drrun -c $B/libpagestate.so -mode check -page_shift $s $(policy_opts $c) \
                -out $T/r -list $T/l -- $(cmd_of $name) >/dev/null 2>&1
            app=$(cmd_of $name | cut -d' ' -f1 | xargs basename)
            cp "$(ls -S $T/r.$app.*.txt | head -n 1)" $SRC/results/check-$name-$s-$c.txt
            lst=$(ls -S $T/l.$app.*.plain 2>/dev/null | head -n 1)
            [ -n "$lst" ] && sort "$lst" >$R/build/lists/$name-check-$s-$c.plain
            echo "== $name check page_shift $s policy $c"
            grep -E '^(faults|collapsed|store |vector store|load )' $SRC/results/check-$name-$s-$c.txt
        done
    done
done

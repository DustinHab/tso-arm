#!/bin/sh
# Test machine: `tso-arm learn` on position-independent programs (build/x86spie: static-pie, build/x86pie: PIE linked
# dynamically, with the minimal root file system build/rootfs-x86), then each run with and without what it learned
# (median of 3, outputs checked against the native ones).
#   tests/pie_learn.sh [DIR/WORKLOAD...]
cd "$(dirname "$0")/.."
export FEX_ROOTFS=$PWD/build/rootfs-x86
C=$PWD/build
args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "-n -p 4 -c $C/corpus.tar" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
}
med() {
    t=""
    for i in 1 2 3; do
        s=$(date +%s%N)
        bin/tso-arm run "$@" >/dev/shm/pl-out 2>/dev/null
        e=$(date +%s%N)
        t="$t $(( (e - s) / 1000000 ))"
    done
    echo $t | tr ' ' '\n' | sort -n | sed -n 2p
}
for p in ${*:-x86spie/pigz x86pie/pigz x86pie/xz x86pie/zstd}; do
    w=$(basename $p)
    prog=build/$p
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    bin/tso-arm forget $prog >/dev/null
    plain=$(med $prog $(args_of $w))
    bin/tso-arm learn $prog $(args_of $w) 2>&1 | grep -E 'chosen|library|left out|learned' | sed 's/^/    /'
    learned=$(med $prog $(args_of $w))
    [ "$(md5sum </dev/shm/pl-out | cut -c1-8)" = "$want" ] && ok=ok || ok=WRONG
    echo "$p: page protocol alone $plain ms, with the learned functions $learned ms, output $ok"
done
rm -f /dev/shm/pl-out

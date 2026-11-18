#!/bin/sh
# Test machine: Box64 against native and tso-arm in one session. Box64 refuses static binaries, so it runs the
# dynamically linked builds (study/build_dynamic.sh: the same sources and options, only the C library dynamic,
# which Box64 runs as native Arm code). Settings: BOX64_DYNAREC_STRONGMEM=0 (its default, no ordering), 1 (some
# barriers on stores), 4 (x86 TSO the way QEMU does it). Best of ROUNDS (default 3) at a fixed clock, every run
# started cool, outputs checked; then FEX's litmus tests under each Box64 setting.
#   bench/box64.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
B=$HOME/src/box64/build/box64
X=$PWD/build/x86
D=$PWD/build/x86dyn
N=$PWD/build/arm64
C=$PWD/build
chmod +x $D/*
rounds=${ROUNDS:-3}
args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "-n -p 4 -c $C/corpus.tar" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
}
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done; }
run() { # config workload -> "seconds ok|WRONG"
    w=$2
    case $1 in
    native) set -- $N/$w ;;
    box64-0) set -- env BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_DYNAREC_STRONGMEM=0 $B $D/$w ;;
    box64-1) set -- env BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_DYNAREC_STRONGMEM=1 $B $D/$w ;;
    box64-4) set -- env BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_DYNAREC_STRONGMEM=4 $B $D/$w ;;
    tso-arm) set -- env TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/bx-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 \
        FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=$PWD/out/aot/$w.so $HOME/opt/fex-views/bin/FEX $X/$w ;;
    esac
    cool
    s=$(date +%s%N)
    "$@" $(args_of $w) >/dev/shm/bx-out 2>/dev/null
    e=$(date +%s%N)
    ok=ok
    [ "$(md5sum </dev/shm/bx-out | cut -c1-8)" != "$(grep "^$w " build/expected.md5 | cut -d' ' -f2)" ] && ok=WRONG
    echo "$(( (e - s) / 1000000 )) $ok"
}
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/bx-out' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
rm -f /tmp/bx-*.prof /tmp/bx-res.txt
for w in pigz xz zstd; do run tso-arm $w >/dev/null; done # the profile, as in bench/efficiency.sh's first round
for r in $(seq $rounds); do
    for w in pigz xz zstd; do
        for cfg in native box64-0 box64-1 box64-4 tso-arm; do
            echo "$w $cfg $(run $cfg $w)" | tee -a /tmp/bx-res.txt
        done
    done
done
echo "== best of $rounds (ms, efficiency against native)"
for cfg in native box64-0 box64-1 box64-4 tso-arm; do
    line="$cfg"
    for w in pigz xz zstd; do
        n=$(awk -v w=$w '$1 == w && $2 == "native" && $4 == "ok" { print $3 }' /tmp/bx-res.txt | sort -n | head -n 1)
        b=$(awk -v w=$w -v c=$cfg '$1 == w && $2 == c && $4 == "ok" { print $3 }' /tmp/bx-res.txt | sort -n | head -n 1)
        bad=$(awk -v w=$w -v c=$cfg '$1 == w && $2 == c && $4 != "ok"' /tmp/bx-res.txt | wc -l)
        line="$line  $w ${b:-?} ms $( [ -n "$b" ] && echo "$((100 * n / b)) %")$( [ $bad -gt 0 ] && echo " ($bad wrong)")"
    done
    echo "$line"
done
sh tools/freq.sh restore >/dev/null
echo "== litmus (200,000 iterations each; forbidden outcomes; sb is allowed under x86)"
for s in 0 1 4; do
    for v in mp vec rep stack lb sb; do
        printf 'box64 strongmem %s  ' $s
        env BOX64_LOG=0 BOX64_NOBANNER=1 BOX64_DYNAREC_STRONGMEM=$s taskset -c 2,3 $B $D/mp $v 200000 2>/dev/null | tail -n 1
    done
done

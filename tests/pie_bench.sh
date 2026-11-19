#!/bin/sh
# Test machine: each workload as a classic static program (build/x86), as static-pie (build/x86spie, where built) and as
# a PIE linked dynamically (build/x86pie), each learned by `tso-arm learn` (tests/pie_learn.sh; here first if it has
# not been), through `tso-arm run` with and without what it learned: median of 5, alternating, fixed clock (1.8 GHz),
# every run started cool, outputs checked; native for reference.
#   tests/pie_bench.sh [WORKLOAD...]        (default pigz)
cd "$(dirname "$0")/.."
export LC_ALL=C FEX_ROOTFS=$PWD/build/rootfs-x86
C=$PWD/build
ws=${*:-pigz}
args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "-n -p 4 -c $C/corpus.tar" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
}
for w in $ws; do
    for d in x86 x86spie x86pie; do
        p=build/$d/$w
        if [ -x $p ] && bin/tso-arm status $p | grep -q 'nothing translated'; then
            bin/tso-arm learn $p $(args_of $w) >/dev/null 2>&1 || echo "learn failed: $p"
        fi
    done
done
rm -f /tmp/pb-*
trap 'sh tools/freq.sh restore >/dev/null; rm -f /tmp/pb-* /dev/shm/pb-out' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done; }
for i in 1 2 3 4 5; do
    for w in $ws; do
        want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
        for c in native:arm64 static:x86 static-pie:x86spie pie-dynamic:x86pie; do
            label=${c%%:*}
            p=build/${c#*:}/$w
            [ -x $p ] || continue
            for v in learned plain; do
                [ $label = native ] && [ $v = plain ] && continue
                cool
                s=$(date +%s%N)
                case $label/$v in
                native/*) $p $(args_of $w) ;;
                */learned) bin/tso-arm run $p $(args_of $w) ;;
                *) bin/tso-arm run --no-aot $p $(args_of $w) ;;
                esac >/dev/shm/pb-out 2>/dev/null
                e=$(date +%s%N)
                echo $(( (e - s) / 1000000 )) >>/tmp/pb-$w-$label-$v
                [ "$(md5sum </dev/shm/pb-out | cut -c1-8)" = "$want" ] || echo "WRONG OUTPUT: $label $v $w"
            done
        done
    done
done
for w in $ws; do
    n=$(sort -n /tmp/pb-$w-native-learned | sed -n 3p)
    echo "$w native: $n ms"
    for label in static static-pie pie-dynamic; do
        [ -f /tmp/pb-$w-$label-plain ] || continue
        p=$(sort -n /tmp/pb-$w-$label-plain | sed -n 3p)
        l=$(sort -n /tmp/pb-$w-$label-learned | sed -n 3p)
        echo "$w $label: page protocol alone $p ms ($((100 * n / p)) %), with what was learned $l ms ($((100 * n / l)) %)"
    done
done

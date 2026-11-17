#!/bin/sh
# Code generation changes without any ordering and without views: upstream FEX against the tso-arm build, and the
# tso-arm build with each change switched off. User instructions and cycles, output checked.
#   bench/codegen.sh [workload ...]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/cg-out' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for w in ${*:-pigz xz zstd}; do
    case $w in
    zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) args="-n -p 4 -c $C/corpus.tar" ;;
    xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    for cfg in ${CONFIGS:-upstream all nonarrow nosplit cse cse2}; do
        bin=$HOME/opt/fex-views/bin/FEX
        case $cfg in
        upstream) bin=$HOME/opt/fex/bin/FEX vars="" ;;
        all) vars="" ;;
        nonarrow) vars="TSO_ARM_NONARROW=1" ;;
        cse) vars="TSO_ARM_CSE=1" ;;
        cse2) vars="TSO_ARM_CSE=2" ;;
        nosplit) vars="TSO_ARM_NOSPLIT=1" ;;
        esac
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        r=$(env FEX_TSOENABLED=0 $vars perf stat -x, -e instructions:u,cycles:u -o /tmp/cg.perf $bin $X/$w $args >/dev/shm/cg-out 2>/dev/null; echo $?)
        sum=$(md5sum </dev/shm/cg-out | cut -c1-8)
        ok=ok
        [ "$sum" != "$want" ] && ok=WRONG
        [ "$r" != 0 ] && ok="exit$r"
        printf '%-5s %-9s %s %s\n' $w $cfg "$(awk -F, '/instructions|cycles/ { printf "%s %.3f G  ", $3, $1 / 1e9 }' /tmp/cg.perf)" $ok
    done
done

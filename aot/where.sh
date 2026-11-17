#!/bin/sh
# Test machine: where the time of xz with translated functions goes. FEX's fixed cost (start-up and exit with an empty
# input), and user cycles per function: native build against FEX with the translated library (no ordering).
#   aot/where.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done; }
args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar"
for cfg in native fex; do
    cool
    case $cfg in
    native) cmd="$N/xz" ;;
    fex) cmd="$HOME/opt/fex-views/bin/FEX $X/xz" ;;
    esac
    s=$(date +%s.%N)
    for i in 1 2 3 4 5; do env FEX_TSOENABLED=0 TSO_AOT=$PWD/out/aot/xz.so $cmd -T4 -6 -c /dev/null >/dev/null; done
    e=$(date +%s.%N)
    printf '%-7s empty input: %.1f ms per run\n' $cfg "$(echo "($e - $s) * 200" | bc)"
done
cool
perf stat -x, -e cycles:u,instructions:u -o /tmp/w-n.txt $N/xz $args >/dev/null
cool
env FEX_TSOENABLED=0 TSO_AOT=$PWD/out/aot/xz.so perf stat -x, -e cycles:u,instructions:u -o /tmp/w-a.txt $HOME/opt/fex-views/bin/FEX $X/xz $args >/dev/null
for f in /tmp/w-n.txt /tmp/w-a.txt; do
    printf '%s: %s\n' $f "$(awk -F, '/cycles|instructions/ { printf "%s %.3f G  ", $3, $1 / 1e9 }' $f)"
done
cool
env FEX_TSOENABLED=0 TSO_AOT=$PWD/out/aot/xz.so perf record -q -e cycles:u -o /tmp/w-perf.data $HOME/opt/fex-views/bin/FEX $X/xz $args >/dev/null 2>&1
perf report -i /tmp/w-perf.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 25

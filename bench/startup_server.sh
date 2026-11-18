#!/bin/sh
# Test machine: FEX's start-up with and without a running FEXServer (it exits one second after its last client, so
# runs with a pause between them start it anew): a workload with its translated library on an empty input, median
# of 9, fixed clock; cold = no server before each run, warm = runs back to back.
#   bench/startup_server.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
F=$HOME/opt/fex-views/bin/FEX
V="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=$PWD/out/aot/$w.so"
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for mode in warm cold; do
    t=""
    for i in $(seq 9); do
        if [ $mode = cold ]; then
            pkill -x FEXServer 2>/dev/null
            while pgrep -x FEXServer >/dev/null; do sleep 0.1; done
        fi
        s=$(date +%s%N)
        env $V $F $X/$w $args >/dev/null 2>&1
        e=$(date +%s%N)
        t="$t $(( (e - s) / 10000 ))"
    done
    printf '%-5s %6.2f ms   (%s)\n' $mode "$(echo "$(echo $t | tr ' ' '\n' | sort -n | sed -n 5p) / 100" | bc -l)" "$(echo $t)"
done
echo "FEXServer alive after the last run: $(pgrep -x FEXServer >/dev/null && echo yes || echo no)"
sleep 1.5
echo "after 1.5 s: $(pgrep -x FEXServer >/dev/null && echo yes || echo no)"

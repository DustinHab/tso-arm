#!/bin/sh
# Test machine: FEX's fixed cost per process (a workload on an empty input): upstream FEX, the tso-arm build without
# and with views, and FEX settings that touch the start-up (telemetry written at exit, multiblock compilation).
# Wall time per run (median of 9) and user/system time of one run.
#   bench/startup.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1"
for cfg in upstream tso-arm views views-notelemetry views-notelemetry-nomultiblock; do
    case $cfg in
    upstream) bin=$HOME/opt/fex/bin/FEX vars="FEX_TSOENABLED=0" ;;
    tso-arm) bin=$HOME/opt/fex-views/bin/FEX vars="FEX_TSOENABLED=0" ;;
    views) bin=$HOME/opt/fex-views/bin/FEX vars="$P" ;;
    views-notelemetry) bin=$HOME/opt/fex-views/bin/FEX vars="$P FEX_DISABLETELEMETRY=1" ;;
    views-notelemetry-nomultiblock) bin=$HOME/opt/fex-views/bin/FEX vars="$P FEX_DISABLETELEMETRY=1 FEX_MULTIBLOCK=0" ;;
    esac
    t=""
    for i in 1 2 3 4 5 6 7 8 9; do
        s=$(date +%s%N)
        env $vars $bin $X/$w $args >/dev/null 2>&1
        e=$(date +%s%N)
        t="$t $(( (e - s) / 100000 ))"
    done
    med=$(echo $t | tr ' ' '\n' | sort -n | sed -n 5p)
    us=$( { env $vars /usr/bin/time -f '%U %S' $bin $X/$w $args >/dev/null 2>/dev/null; } 2>&1 | tail -n 1)
    printf '%-32s %5.1f ms   user/sys %s s\n' $cfg "$(echo "$med / 10" | bc -l)" "$us"
done

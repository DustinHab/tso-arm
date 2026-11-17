#!/bin/sh
# Test machine: FEX's fixed cost per process (xz on an empty input): upstream FEX, the tso-arm build without and with
# views, wall time per run (median of 9) and user/system time of one run.
#   bench/startup.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
for cfg in upstream tso-arm views views-aot; do
    case $cfg in
    upstream) bin=$HOME/opt/fex/bin/FEX vars="FEX_TSOENABLED=0" ;;
    tso-arm) bin=$HOME/opt/fex-views/bin/FEX vars="FEX_TSOENABLED=0" ;;
    views) bin=$HOME/opt/fex-views/bin/FEX vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none" ;;
    views-aot) bin=$HOME/opt/fex-views/bin/FEX vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none TSO_AOT=$PWD/out/aot/xz.so" ;;
    esac
    t=""
    for i in 1 2 3 4 5 6 7 8 9; do
        s=$(date +%s%N)
        env $vars $bin $X/xz -T4 -6 -c /dev/null >/dev/null
        e=$(date +%s%N)
        t="$t $(( (e - s) / 100000 ))"
    done
    med=$(echo $t | tr ' ' '\n' | sort -n | sed -n 5p)
    us=$( { env $vars /usr/bin/time -f '%U %S' $bin $X/xz -T4 -6 -c /dev/null >/dev/null; } 2>&1 | tail -n 1)
    printf '%-10s %5.1f ms   user/sys %s s\n' $cfg "$(echo "$med / 10" | bc -l)" "$us"
done

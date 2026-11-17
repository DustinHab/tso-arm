#!/bin/sh
# Wall time and fallback moment of pigz and zstd for several fallback warm-up times and windows.
#   bench/fallback_sweep.sh ["WARMUP:WINDOW ..."]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for p in ${1:-300:1000 150:500 100:250 50:250}; do
    warm=${p%:*}
    win=${p#*:}
    for w in pigz zstd; do
        case $w in
        zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
        pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
        esac
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        /usr/bin/time -f '%e' -o /tmp/fs.time env TSO_VIEWS=1 TSO_VIEWS_STATS=1 TSO_VIEWS_WARMUP=$warm TSO_VIEWS_WINDOW=$win \
            FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>/tmp/fs.err
        printf '%-9s %-5s %6s s  %s\n' "$warm:$win" $w "$(cat /tmp/fs.time)" "$(grep -o 'fell back.*' /tmp/fs.err)"
    done
done

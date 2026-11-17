#!/bin/sh
# First runs (no profile) of pigz, xz, zstd under several migration settings. Wall time, best of ROUNDS.
#   bench/migrate_sweep.sh ["NAME=VARS ..."]   VARS separated by commas
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
ROUNDS=${ROUNDS:-2}
SETS=${1:-"nomig=TSO_VIEWS_MIGRATE=0 q1ms=TSO_VIEWS_MIGRATE=1,TSO_VIEWS_QUICK=1000 q20ms0=TSO_VIEWS_MIGRATE=1,TSO_VIEWS_QUICK=20000,TSO_VIEWS_STRIKES=0 q20ms0page=TSO_VIEWS_MIGRATE=1,TSO_VIEWS_QUICK=20000,TSO_VIEWS_STRIKES=0,TSO_VIEWS_CHUNKMIG=0"}
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for set in $SETS; do
    name=${set%%=*}
    vars=$(echo "${set#*=}" | tr ',' ' ')
    line="$name"
    for w in pigz xz zstd; do
        case $w in
        zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
        pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
        xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
        esac
        best=999
        for r in $(seq 1 $ROUNDS); do
            while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
            /usr/bin/time -f '%e' -o /tmp/ms.time env TSO_VIEWS=1 TSO_VIEWS_PROFILE=none $vars \
                FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>/dev/null
            best=$(echo "$(cat /tmp/ms.time) $best" | awk '{print ($1 < $2) ? $1 : $2}')
        done
        line="$line  $w $best"
    done
    echo "$line"
done

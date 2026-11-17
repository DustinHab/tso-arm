#!/bin/sh
# One workload with a fresh profile: first run and runs with the profile, with the fallback allowed (default budget)
# and without it (TSO_VIEWS_BUDGET=0). Wall time per run.
#   bench/profile_modes.sh [workload]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=${1:-zstd}
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for budget in default 0; do
    P=/tmp/tso-modes-$budget.prof
    rm -f $P
    for r in 1 2 3 4; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        if [ $budget = default ]; then b=5000; else b=0; fi
        /usr/bin/time -f '%e' -o /tmp/pm.time env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$P TSO_VIEWS_BUDGET=$b TSO_VIEWS_STATS=1 \
            FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>/tmp/pm.err
        printf 'budget %-7s run %d: %s s  %s\n' $budget $r "$(cat /tmp/pm.time)" "$(grep -o 'handled faults.*' /tmp/pm.err)"
    done
done

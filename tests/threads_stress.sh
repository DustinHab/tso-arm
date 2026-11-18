#!/bin/sh
# Test machine: the threads test beyond the view slots many times under the page protocol (and without ordering, as
# a control), counting the runs that fail; the stderr of the first failing ones kept in /tmp/ts-fail-N.txt.
#   tests/threads_stress.sh [RUNS] [THREADS] [FEX]
cd "$(dirname "$0")/.."
runs=${1:-200}
n=${2:-20}
F=${3:-$HOME/opt/fex-views/bin/FEX}
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
for cfg in protocol unordered; do
    [ $cfg = unordered ] && vars="FEX_TSOENABLED=0 FEX_DISABLETELEMETRY=1" || vars=$P
    fail=0
    for i in $(seq $runs); do
        out=$(env $vars ${EXTRA:-} timeout 120 $F build/threads-x86 $n 2>/tmp/ts-err.txt | tail -n 1)
        rc=$?
        if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'wrong 0'; then
            fail=$((fail + 1))
            [ $fail -le 3 ] && cp /tmp/ts-err.txt /tmp/ts-fail-$cfg-$fail.txt
        fi
    done
    echo "$cfg: $fail of $runs runs with $n threads failed"
done

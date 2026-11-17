#!/bin/sh
# Runs a program under the page protocol N times; prints exit status and last output line of each run.
#   tools/repeat.sh N [VAR=value ...] program args...     (env TSO_VIEWS_* settings go first)
cd "$(dirname "$0")/.."
n=$1
shift
for i in $(seq 1 $n); do
    timeout 120 env TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 "$@" >/tmp/rep.out 2>/tmp/rep.err
    rc=$?
    echo "run $i: exit $rc | $(tail -n 1 /tmp/rep.out | tr '\0' '@' | cut -c1-100) | $(grep -v '^tso-arm: \(fault\|escalate\|boundary\|  \)' /tmp/rep.err | tail -n 2 | tr '\n' ' ' | cut -c1-300)"
done

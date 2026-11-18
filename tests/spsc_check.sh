#!/bin/sh
# Test machine: tests/spsc.c (a ring buffer that relies on x86 memory order, build/spsc-x86) under FEX without
# ordering, FEX's full TSO and tso-arm: how many messages arrive wrong, and the time.
#   tests/spsc_check.sh [MESSAGES]
cd "$(dirname "$0")/.."
n=${1:-20000000}
F=$HOME/opt/fex-views/bin/FEX
for cfg in unordered full tso-arm; do
    case $cfg in
    unordered) vars="FEX_TSOENABLED=0" ;;
    full) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
    tso-arm) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
    esac
    s=$(date +%s%N)
    out=$(env $vars FEX_DISABLETELEMETRY=1 timeout 600 $F build/spsc-x86 $n 2>/dev/null)
    rc=$?
    e=$(date +%s%N)
    printf '%-10s exit %d, %5d ms | %s\n' $cfg $rc $(( (e - s) / 1000000 )) "$out"
done

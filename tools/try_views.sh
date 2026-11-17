#!/bin/sh
# One program under FEX with the page protocol, with FEX's log and the exit status.
#   tools/try_views.sh PROGRAM [ARGS...]      (extra environment: VIEWS_ENV="...")
cd "$(dirname "$0")/.."
env TSO_VIEWS=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_SILENTLOG=0 FEX_OUTPUTLOG=stderr $VIEWS_ENV \
    timeout ${TIMEOUT:-60} ~/opt/fex-views/bin/FEX "$@" >/tmp/try.out 2>/tmp/try.err
echo "exit $?"
echo "-- stdout"; head -c 2000 /tmp/try.out | tail -n 5
echo "-- stderr"; grep -v '^$' /tmp/try.err | tail -n ${LINES_ERR:-25}

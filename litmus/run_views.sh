#!/bin/sh
# Litmus tests under FEX with the page protocol (views). Result in out/litmus_views.txt.
#   litmus/run_views.sh [iterations]      (extra protocol settings: VIEWS_ENV="TSO_VIEWS_MIGRATE=1 ...")
#   FEXV: another tso-arm FEX (the installed one: ~/.local/opt/tso-arm/bin/FEX)
cd "$(dirname "$0")/.."
F=${FEXV:-$HOME/opt/fex-views/bin/FEX}
N=${1:-2000000}
out=out/litmus_views.txt
mkdir -p out
: >$out
for v in ${VARIANTS:-mp vec rep stack stackflag vecflag repflag vecwait lb sb}; do
    r=$(env TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $VIEWS_ENV timeout 600 taskset -c 2,3 \
        $F build/mp-x86 $v $N 2>&1 | tail -n 1)
    printf '%-20s %s\n' "views protocol" "$r" | tee -a $out
done

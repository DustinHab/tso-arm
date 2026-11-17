#!/bin/sh
# Litmus tests under FEX with the page protocol (views). Result in out/litmus_views.txt.
#   litmus/run_views.sh [iterations]
cd "$(dirname "$0")/.."
N=${1:-2000000}
out=out/litmus_views.txt
mkdir -p out
: >$out
for v in ${VARIANTS:-mp vec rep stack stackflag vecflag repflag vecwait lb sb}; do
    r=$(env TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 timeout 600 taskset -c 2,3 \
        $HOME/opt/fex-views/bin/FEX build/mp-x86 $v $N 2>&1 | tail -n 1)
    printf '%-20s %s\n' "views protocol" "$r" | tee -a $out
done

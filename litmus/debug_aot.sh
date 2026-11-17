#!/bin/sh
# One litmus variant with translated thread functions under the page protocol, logged, filtered to what goes wrong.
#   litmus/debug_aot.sh [VARIANT] [iterations] [repeats]
cd "$(dirname "$0")/.."
v=${1:-mp}
n=${2:-200000}
for i in $(seq ${3:-3}); do
    TSO_VIEWS=1 TSO_VIEWS_LOG=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 TSO_AOT=$PWD/out/aot/mp.so \
        timeout 300 $HOME/opt/fex-views/bin/FEX build/mp-x86 $v $n 2>&1 |
        grep -a 'not ours\|cannot\|keeps\|iterations\|fell\|ERROR\|rror\|unreachable' | head -n 8
    echo "run $i done"
done

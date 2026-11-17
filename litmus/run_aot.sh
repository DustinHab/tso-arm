#!/bin/sh
# Litmus tests with the thread functions translated ahead of time (aot/): under FEX without ordering (the forbidden
# outcomes should show, so the test can see them) and under the page protocol (none allowed).
# Result in out/litmus_aot.txt.
#   litmus/run_aot.sh [iterations]
cd "$(dirname "$0")/.."
N=${1:-200000}
out=out/litmus_aot.txt
mkdir -p out/aot
python3 aot/lift.py build/mp-x86 out/aot/mp.c thread_a thread_b thread_pair >/dev/null || exit 1
sh aot/build.sh out/aot/mp.c out/aot/mp.so || exit 1
: >$out
for cfg in off ordered protocol; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0" ;;
    # FEX with full ordering, the translated functions in their ordered variants from the start
    ordered) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 TSO_AOT_ORDERED=1" ;;
    protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
    esac
    for v in ${VARIANTS:-mp vec rep vecflag repflag vecwait lb sb}; do
        r=$(env $vars TSO_AOT=$PWD/out/aot/mp.so timeout 900 taskset -c 2,3 $HOME/opt/fex-views/bin/FEX build/mp-x86 $v $N 2>&1 | tail -n 1)
        printf '%-14s %s\n' "aot $cfg" "$r" | tee -a $out
    done
done

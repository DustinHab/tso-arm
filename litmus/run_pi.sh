#!/bin/sh
# Runs the x86-64 litmus tests under FEX and Box64 with different ordering settings. Result in out/litmus.txt.
#   litmus/run_pi.sh [iterations]
cd "$(dirname "$0")/.."
N=${1:-2000000}
FEX=$HOME/opt/fex/bin/FEX
BOX=$HOME/src/box64/build/box64
T=$PWD/build/mp-x86
out=out/litmus.txt
mkdir -p out
: >$out
# run LABEL TRANSLATOR [VAR=VALUE ...]
run() {
    label=$1
    tr=$2
    shift 2
    for v in ${VARIANTS:-mp vec rep stack stackflag vecflag repflag vecwait lb sb}; do
        r=$(env "$@" timeout 300 taskset -c 2,3 $tr $T $v $N 2>&1 | tail -n 1)
        printf '%-20s %s\n' "$label" "$r" | tee -a $out
    done
}
run "fex default" $FEX
run "fex tso off" $FEX FEX_TSOENABLED=0
run "fex full tso" $FEX FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1
run "box64 default" $BOX BOX64_LOG=0
run "box64 strongmem 1" $BOX BOX64_LOG=0 BOX64_DYNAREC_STRONGMEM=1
run "box64 strongmem 3" $BOX BOX64_LOG=0 BOX64_DYNAREC_STRONGMEM=3

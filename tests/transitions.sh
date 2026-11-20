#!/bin/sh
# Test machine: what a call across the border of translated code costs (tests/transitions.c, built for x86-64 into
# build/x86/transitions): per call from guest code into a translated function, and per call from translated code into
# guest code, against the same program with no library (FEX without ordering, block by block in both, 3 runs each).
#   tests/transitions.sh [N]       default 10 million calls
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86/transitions
[ -x $X ] || { echo "no $X (x86-64: gcc -O2 -static -no-pie -o build/x86/transitions tests/transitions.c)"; exit 1; }
n=${1:-10000000}
F=${TSO_ARM_FEX:-$HOME/opt/fex-views/bin/FEX}
mkdir -p out/aot
for f in into out_loop; do
    python3 aot/lift.py $X out/aot/tr-$f.c $f >/dev/null && sh aot/build.sh out/aot/tr-$f.c out/aot/tr-$f.so || exit 1
done
best() { # env... -> best wall time of 3 in ms, and the output
    b=""
    for i in 1 2 3; do
        s=$(date +%s%N)
        o=$(env FEX_DISABLETELEMETRY=1 FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 "$@")
        e=$(date +%s%N)
        t=$(( (e - s) / 1000000 ))
        [ -z "$b" ] || [ $t -lt $b ] && b=$t
    done
    echo "$b $o"
}
for m in in out; do
    case $m in in) lib=out/aot/tr-into.so ;; out) lib=out/aot/tr-out_loop.so ;; esac
    set -- $(best $F $X $m $n)
    t0=$1 o0=$2
    set -- $(best TSO_AOT=$PWD/$lib $F $X $m $n)
    t1=$1 o1=$2
    same=$([ "$o0" = "$o1" ] && echo "output the same" || echo "OUTPUT DIFFERS")
    echo "$m: FEX alone $t0 ms, with $(basename $lib) $t1 ms for $n calls: $(( (t1 - t0) * 1000000 / n )) ns more per call; $same"
done

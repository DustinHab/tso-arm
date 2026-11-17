#!/bin/sh
# Builds the study client and the pattern programs in WSL and runs each pattern under it.
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/run_patterns.sh
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
B=$HOME/study/build
DR=/opt/dynamorio/current
mkdir -p $B $SRC/results
cmake -S $SRC -B $B -G Ninja -DDynamoRIO_DIR=$DR/cmake -DCMAKE_BUILD_TYPE=Release >$B/cmake.log 2>&1 || { tail -30 $B/cmake.log; exit 1; }
ninja -C $B >$B/ninja.log 2>&1 || { tail -40 $B/ninja.log; exit 1; }
gcc -O2 -pthread -static -o $B/patterns $SRC/work/patterns.c
for p in ${*:-private table shared queue}; do
    echo "== $p"
    timeout 900 $DR/bin64/drrun -c $B/libpagestate.so -out $SRC/results/patterns-$p.txt -- $B/patterns $p
    cat $SRC/results/patterns-$p.txt
done

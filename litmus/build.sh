#!/bin/sh
# Builds the x86-64 litmus tests (static) in WSL and runs them natively as a reference.
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/litmus/build.sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p $R/build
gcc -O2 -static -pthread -o $R/build/mp-x86 $R/litmus/mp.c
for v in mp vec rep stack stackflag vecflag repflag vecwait lb sb; do
    taskset -c 2,3 $R/build/mp-x86 $v 1000000 || true
done

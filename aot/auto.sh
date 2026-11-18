#!/bin/sh
# Test machine: aot/auto.py for one of the benchmark workloads, with its benchmark input: the library
# out/aot/WORKLOAD_auto.so, and the functions chosen in aot/lists/WORKLOAD.list, which aot/WORKLOAD.sh builds from.
#   aot/auto.sh WORKLOAD [auto.py options]
cd "$(dirname "$0")/.."
w=$1
shift
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
mkdir -p out/aot aot/lists
python3 aot/auto.py build/x86/$w out/aot/${w}_auto.so "$@" -- $args && cp out/aot/${w}_auto.so.list aot/lists/$w.list

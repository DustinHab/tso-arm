#!/bin/sh
# Test machine: zstd's library of functions translated ahead of time, out/aot/zstd.so (the functions:
# aot/lists/zstd.list, chosen by aot/auto.sh; the double-fast match finder, sequence and entropy encoding, block
# splitting, XXH64).
#   aot/zstd.sh
exec sh "$(dirname "$0")/build_lib.sh" zstd

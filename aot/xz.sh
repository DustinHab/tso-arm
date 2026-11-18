#!/bin/sh
# Test machine: xz's library of functions translated ahead of time, out/aot/xz.so (the functions:
# aot/lists/xz.list, chosen by aot/auto.sh; the LZMA encoder and the bt4 match finder).
#   aot/xz.sh
exec sh "$(dirname "$0")/build_lib.sh" xz

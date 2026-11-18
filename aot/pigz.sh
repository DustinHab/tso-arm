#!/bin/sh
# Test machine: pigz's library of functions translated ahead of time, out/aot/pigz.so (the functions:
# aot/lists/pigz.list, chosen by aot/auto.sh; zlib's deflate_slow with its match search, window sliding and block
# output, and the checksums).
#   aot/pigz.sh
exec sh "$(dirname "$0")/build_lib.sh" pigz

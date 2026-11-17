#!/bin/sh
# Test machine: translates the hot functions of the x86-64 pigz (zlib's deflate_slow with its match search, window
# sliding and block output, and crc32_z) ahead of time and builds the library FEX loads with TSO_AOT=out/aot/pigz.so.
#   aot/pigz.sh
cd "$(dirname "$0")/.."
mkdir -p out/aot
python3 aot/lift.py build/x86/pigz out/aot/pigz.c \
    deflate_slow longest_match fill_window slide_hash read_buf flush_pending _tr_flush_bits _tr_flush_block \
    _tr_stored_block compress_block build_tree pqdownheap scan_tree send_tree bi_windup crc32_z deflateSetDictionary \
    deflateStateCheck ${STRINGS:---strings} $(sh aot/strings_specs.sh build/x86/pigz) || exit 1
sh aot/build.sh out/aot/pigz.c out/aot/pigz.so

#!/bin/sh
# Test machine: translates the hot functions of the x86-64 xz (the LZMA encoder and the bt4 match finder) ahead of time
# and builds the library FEX loads with TSO_AOT=out/aot/xz.so.
#   aot/xz.sh
cd "$(dirname "$0")/.."
mkdir -p out/aot
python3 aot/lift.py build/x86/xz out/aot/xz.c \
    lzma_lzma_encode length length_update_prices lzma_lzma_optimum_normal lzma_lzma_optimum_fast rc_encode get_literal_price \
    lzma_mf_find lzma_mf_bt4_find lzma_mf_bt4_skip bt_find_func bt_skip_func move_pos || exit 1
sh aot/build.sh out/aot/xz.c out/aot/xz.so

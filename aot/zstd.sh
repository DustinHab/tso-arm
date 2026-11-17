#!/bin/sh
# Test machine: translates the hot functions of the x86-64 zstd (the double-fast match finder, sequence encoding with
# its statistics, block splitting, XXH64) ahead of time and builds the library FEX loads with
# TSO_AOT=out/aot/zstd.so.
#   aot/zstd.sh
cd "$(dirname "$0")/.."
mkdir -p out/aot
python3 aot/lift.py build/x86/zstd out/aot/zstd.c \
    ZSTD_compressBlock_doubleFast ZSTD_safecopyLiterals@422540 ZSTD_encodeSequences_bmi2 ZSTD_encodeSequences \
    ZSTD_XXH64_update ZSTD_splitBlock HIST_add ZSTD_recordFingerprint_1 ZSTD_recordFingerprint_5 \
    ZSTD_recordFingerprint_11 ZSTD_recordFingerprint_43 ZSTD_buildSequencesStatistics ZSTD_seqToCodes \
    HIST_countFast_wksp HIST_count_simple HIST_count_parallel_wksp || exit 1
sh aot/build.sh out/aot/zstd.c out/aot/zstd.so

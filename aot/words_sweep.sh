#!/bin/sh
# Test machine: unaligned ordered loads as ldr + dmb ishld (AOT_WORDS=0) or as ldapr of the covering aligned words for
# loads of AOT_WORDS bytes and more; zstd in the protocol's fallback (ordered throughout), median of 5.
#   aot/words_sweep.sh
cd "$(dirname "$0")/.."
for n in ${WORDS:-0 8 4 2}; do
    CFLAGS="-O2 -DAOT_WORDS=$n" sh aot/zstd.sh >/dev/null 2>&1 || { echo "build failed"; exit 1; }
    printf 'AOT_WORDS=%s  ' $n
    MODES=fallback sh aot/zstd_fallback.sh 2>&1 | head -n 1
done
sh aot/zstd.sh >/dev/null 2>&1

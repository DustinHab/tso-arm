#!/bin/sh
# Native x86-64 reference: first 8 hex digits of the md5 of each workload's output -> build/expected.md5
R=$(cd "$(dirname "$0")/.." && pwd)
X=$R/build/x86
C=$R/build
{
    echo "zstd $($X/zstd -T4 -3 -f -q -c $C/corpus.tar | md5sum | cut -c1-8)"
    echo "pigz $($X/pigz -n -p 4 -c $C/corpus.tar | md5sum | cut -c1-8)"
    echo "xz $($X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar | md5sum | cut -c1-8)"
} | tee $R/build/expected.md5

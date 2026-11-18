#!/bin/sh
# Test machine: 7-Zip's built-in benchmark (build/x86/7zz, static x86-64), which compresses and decompresses with
# several threads and checks every result itself, through `tso-arm run` with x86 order kept and with FEX's full
# ordering; the exit status, errors and the benchmark's total rating.
#   tests/sevenzip_check.sh
cd "$(dirname "$0")/.."
for mode in tso full; do
    s=$(date +%s)
    out=$(bin/tso-arm run --mode $mode build/x86/7zz b -mmt4 -md22 2>&1)
    rc=$?
    e=$(date +%s)
    printf '%-5s exit %d, %d s, %s errors | %s\n' $mode $rc $((e - s)) "$(echo "$out" | grep -ci 'error')" \
        "$(echo "$out" | grep '^Tot:' | tr -s ' ' | cut -c1-80)"
done

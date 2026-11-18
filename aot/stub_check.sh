#!/bin/sh
# Test machine: the patch stubs' general path for every patched load as well (TSO_AOT_NOFAST=1), each workload twice
# under the page protocol, then the views matrix and the litmus series (aot/check_all.sh).
#   aot/stub_check.sh [LITMUS_ITERATIONS]
cd "$(dirname "$0")/.."
for w in pigz xz zstd; do
    for i in 1 2; do
        AOT_ENV=TSO_AOT_NOFAST=1 sh aot/try.sh $w protocol 2>&1 | grep -E "^$w aot " | sed 's/$/ (general path)/'
    done
done
sh tools/views_matrix.sh 2>&1 | grep -E 'exit|wrong|forbidden' | grep -v '^thread' | tail -n 12
sh aot/check_all.sh ${1:-200000} 2>&1 | grep -E 'forbidden|allowed|aot '

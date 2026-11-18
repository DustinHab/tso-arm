#!/bin/sh
# Test machine: correctness after a change to the protocol or the translator: the three workloads with their
# translated functions under the page protocol (outputs checked), FEX's litmus tests under the protocol and the
# litmus tests with translated thread functions.
#   aot/check_all.sh [LITMUS_ITERATIONS]
cd "$(dirname "$0")/.."
n=${1:-200000}
for w in pigz xz zstd; do
    sh aot/try.sh $w protocol 2>&1 | grep -E "^$w aot "
done
sh litmus/run_views.sh $n 2>&1 | tail -n 12
sh litmus/run_aot.sh $n 2>&1 | tail -n 12

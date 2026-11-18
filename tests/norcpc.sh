#!/bin/sh
# Test machine: the code paths for cores without FEAT_LRCPC (Cortex-A53, A72), forced on the test machine: the
# libraries built for Armv8.0 (AOT_NORCPC=1: ldar instead of ldapr) and the patch stubs with ldar
# (TSO_AOT_NORCPC=1). The three workloads under the page protocol (outputs checked) and the litmus tests with
# translated thread functions; the libraries are rebuilt as usual afterwards.
#   tests/norcpc.sh
cd "$(dirname "$0")/.."
for w in pigz xz zstd; do
    AOT_NORCPC=1 sh aot/$w.sh >/dev/null 2>&1 || { echo "$w: build failed"; exit 1; }
    printf '%s: %s ldapr, %s ldar in the library\n' $w "$(objdump -d out/aot/$w.so | grep -c 'ldapr')" "$(objdump -d out/aot/$w.so | grep -c 'ldar')"
    AOT_ENV=TSO_AOT_NORCPC=1 sh aot/try.sh $w protocol 2>&1 | grep -E "^$w aot "
done
AOT_NORCPC=1 TSO_AOT_NORCPC=1 sh litmus/run_aot.sh 100000 2>&1 | tail -n 12
for w in pigz xz zstd; do sh aot/$w.sh >/dev/null 2>&1; done

#!/bin/sh
# Compiles a translated C file (aot/lift.py) into the library FEX loads with TSO_AOT.
#   aot/build.sh IN.c OUT.so      CFLAGS overrides -O2
set -e
dir=$(cd "$(dirname "$0")" && pwd)
in=$1
out=$2
rt=$(mktemp -d)
trap 'rm -rf "$rt"' EXIT
cat >"$rt/aot-rt.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
__attribute__((noreturn, cold)) void aot_unreachable(uint64_t rip)
{
    fprintf(stderr, "tso-arm aot: reached untranslated path at guest %#llx\n", (unsigned long long)rip);
    abort();
}
EOF
# +rcpc: acquire loads as LDAPR (x86 loads need no more than release consistency against earlier stores), where the
# core has it (FEAT_LRCPC: Cortex-A55, A75, A76 and later); older cores (Cortex-A53, A72) get LDAR, which orders at
# least as strongly. AOT_NORCPC=1 builds the latter on any core, for testing.
# rcpc-immo: with FEAT_LRCPC2 (Neoverse N2, V1, Cortex-A710 and later; "ilrcpc") the ordered accesses take an
# immediate offset (LDAPUR, STLUR) and need no address addition of their own, as FEX's own code does there;
# AOT_NOIMMO=1 leaves only this out, for comparing
features=""
if grep -qw lrcpc /proc/cpuinfo && [ -z "$AOT_NORCPC" ]; then
    march=armv8.2-a+rcpc
    if grep -qw ilrcpc /proc/cpuinfo && [ -z "$AOT_NOIMMO" ]; then
        features="-Xclang -target-feature -Xclang +rcpc-immo"
    fi
else
    march=armv8-a
fi
# AOT_U16 where ldapr and stlr may be unaligned within 16 bytes here (FEAT_LSE2 and the kernel allowing it): those
# need no barrier then. AOT_NOU16=1 leaves it out, for comparing
if [ -z "$AOT_NOU16" ] && clang -O1 -march=$march -o "$rt/probe" "$dir/unaligned_probe.c" 2>/dev/null &&
    "$rt/probe" >/dev/null 2>&1; then
    features="$features -DAOT_U16=1"
fi
clang ${CFLAGS:--O2} -march=$march $features -fPIC -shared -I"$dir" -fno-strict-aliasing -Wno-unused-label \
    -Wno-unused-variable -Wno-unused-but-set-variable -o "$out" "$in" "$rt/aot-rt.c"

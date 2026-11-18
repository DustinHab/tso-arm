#!/bin/sh
# Test machine: compiles a translated C file (aot/lift.py) into the library FEX loads with TSO_AOT.
#   aot/build.sh IN.c OUT.so      CFLAGS overrides -O2
dir=$(cd "$(dirname "$0")" && pwd)
in=$1
out=$2
cat >/tmp/aot-rt.c <<'EOF'
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
if grep -qw lrcpc /proc/cpuinfo && [ -z "$AOT_NORCPC" ]; then
    march=armv8.2-a+rcpc
else
    march=armv8-a
fi
clang ${CFLAGS:--O2} -march=$march -fPIC -shared -I"$dir" -fno-strict-aliasing -Wno-unused-label -Wno-unused-variable \
    -Wno-unused-but-set-variable -o "$out" "$in" /tmp/aot-rt.c

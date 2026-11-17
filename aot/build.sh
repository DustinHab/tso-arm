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
# +rcpc: acquire loads as LDAPR (x86 loads need no more than release consistency against earlier stores)
clang ${CFLAGS:--O2} -march=armv8.2-a+rcpc -fPIC -shared -I"$dir" -fno-strict-aliasing -Wno-unused-label -Wno-unused-variable \
    -Wno-unused-but-set-variable -o "$out" "$in" /tmp/aot-rt.c

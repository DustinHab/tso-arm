#!/bin/sh
# On an x86-64 machine (or with CC_X86 a cross compiler): the static x86-64 test programs of tests/ci.sh in build/ci
# (for running tests/ci.sh with SKIP_BUILD=1 where no x86 compiler is installed).
#   tests/build_ci_programs.sh
set -e
cd "$(dirname "$0")/.."
CC=${CC_X86:-gcc}
mkdir -p build/ci
$CC -O2 -static -pthread -o build/ci/mp litmus/mp.c
$CC -O2 -static -pthread -o build/ci/threads tests/threads.c
$CC -O2 -static -pthread -o build/ci/spsc tests/spsc.c
$CC -O2 -static -pthread -o build/ci/sharedstack tests/sharedstack.c
$CC -O2 -static -pthread -o build/ci/fields study/work/fields.c
ls build/ci

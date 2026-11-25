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
$CC -O2 -static -pthread -o build/ci/wake tests/wake.c
$CC -O2 -static -pthread -o build/ci/sharedstack tests/sharedstack.c
$CC -O2 -static -pthread -o build/ci/fields study/work/fields.c
$CC -O2 -static -pthread -o build/ci/fork tests/fork.c
$CC -O2 -static -o build/ci/signals tests/signals.c
$CC -O2 -static -pthread -o build/ci/sigrace tests/sigrace.c
$CC -O2 -static -pthread -o build/ci/smc tests/smc.c
$CC -O2 -static -o build/ci/fdfull tests/fdfull.c
$CC -O2 -static -pthread -o build/ci/exactstart tests/exactstart.c
$CC -O2 -static -pthread -o build/ci/xmc tests/xmc.c
$CC -O2 -static -o build/ci/sigign tests/sigign.c
$CC -O2 -static -pthread -o build/ci/faultaddr tests/faultaddr.c
$CC -O2 -static -pthread -o build/ci/writeonly tests/writeonly.c
$CC -O2 -static -pthread -o build/ci/segload tests/segload.c
$CC -O2 -static -pthread -o build/ci/forksnap tests/forksnap.c
$CC -O2 -static -pthread -o build/ci/forkeintr tests/forkeintr.c
$CC -O2 -static -pthread -o build/ci/preempt tests/preempt.c
$CC -O2 -static -o build/ci/sigspin tests/sigspin.c
$CC -O2 -static -pthread -o build/ci/sigsync tests/sigsync.c
$CC -O2 -static -o build/ci/x87 tests/x87.c
$CC -O2 -static -o build/ci/filemap tests/filemap.c
# 32-bit (gcc-multilib, or CC_X86_32 a cross compiler)
CC32=${CC_X86_32:-"$CC -m32"}
$CC32 -O2 -msse2 -static -pthread -o build/ci/mp32 litmus/mp32.c
$CC32 -O2 -static -pthread -o build/ci/threads32 tests/threads.c
# dynamically linked, with this machine's C library as the root file system
R=build/ci/rootfs
LIBC=$($CC -print-file-name=libc.so.6)
LD=$($CC -print-file-name=ld-linux-x86-64.so.2)
[ -f "$LD" ] || LD=/lib64/ld-linux-x86-64.so.2
if [ -f "$LIBC" ] && [ -f "$LD" ]; then
    mkdir -p $R/lib64 $R/lib
    cp -L "$LD" $R/lib64/
    cp -L "$LIBC" "$($CC -print-file-name=libm.so.6)" $R/lib/
    $CC -O2 -pthread -o build/ci/threads-dyn tests/threads.c
    $CC -O2 -fPIC -shared -Wl,--build-id -o $R/lib/libhot.so tests/sharedlib/libhot.c
    $CC -O2 -Wl,--build-id -o build/ci/dl tests/sharedlib/dl.c
fi
ls build/ci

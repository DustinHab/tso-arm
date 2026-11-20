#!/bin/sh
# Correctness on any Arm machine with tso-arm installed (the CI runs it on GitHub's Arm runners): builds the x86-64
# test programs with a cross compiler, then through `tso-arm run`: the views corner cases (struct fields, a shared
# stack), more threads than view slots, the litmus tests under the page protocol and with translated thread
# functions, and a ring buffer that relies on x86 order. Outputs that need a reference are compared with FEX's own
# full ordering. Exit status 1 on the first failure.
#   tests/ci.sh          CC_X86 (default x86_64-linux-gnu-gcc), ITER (litmus iterations, default 200000)
set -e
cd "$(dirname "$0")/.."
T=bin/tso-arm
CC=${CC_X86:-x86_64-linux-gnu-gcc}
N=${ITER:-200000}
B=build/ci
mkdir -p $B out/aot
fail() {
    echo "FAIL: $*"
    exit 1
}
ok() { echo "ok:   $*"; }

if [ -z "$SKIP_BUILD" ]; then # SKIP_BUILD=1: the programs in build/ci were built elsewhere
    $CC -O2 -static -pthread -o $B/mp litmus/mp.c
    $CC -O2 -static -pthread -o $B/threads tests/threads.c
    $CC -O2 -static -pthread -o $B/spsc tests/spsc.c
    $CC -O2 -static -pthread -o $B/sharedstack tests/sharedstack.c
    $CC -O2 -static -pthread -o $B/fields study/work/fields.c
    $CC -O2 -static -pthread -o $B/fork tests/fork.c
    $CC -O2 -static -o $B/signals tests/signals.c
    $CC -O2 -static -o $B/x87 tests/x87.c
fi
sh tools/board_check.sh | sed 's/^/      /'

# struct fields and a stack shared between threads: the same output as FEX's full ordering
for p in "fields 1000" "sharedstack 2000"; do
    set -- $p
    want=$($T run --mode full $B/$1 $2 | tail -n 1)
    got=$($T run $B/$1 $2 | tail -n 1)
    [ "$got" = "$want" ] || fail "$1: '$got' against '$want'"
    ok "$1: $got"
done

# more threads at once than view slots
for n in 8 16 40; do
    out=$($T run $B/threads $n | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "threads $n: $out"
    ok "threads $n: $out"
done

# fork without exec: the child's memory is its own (guest memory is shared memory under the views), memory mapped
# shared stays shared, read-only memory made writable after the fork is copied
out=$($T run $B/fork | tail -n 1) || fail "$out"
ok "$out"

# the program's own signal handlers, in every mode
for m in tso full unordered; do
    out=$($T run --mode $m $B/signals | tail -n 1) || fail "signals, $m: $out"
    ok "$m: $out"
done

# x87 registers, which FEX addresses in the thread's context: the same results as FEX's full ordering
want=$($T run --mode full $B/x87 | tail -n 1)
got=$($T run $B/x87 | tail -n 1)
[ "$got" = "$want" ] || fail "x87: '$got' against '$want'"
ok "$got"

# litmus tests: no forbidden outcome under the page protocol (mp exits 1 if there was one)
for v in mp vec rep stack stackflag vecflag repflag vecwait lb; do
    out=$($T run $B/mp $v $N | tail -n 1) || fail "litmus $v: $out"
    ok "litmus $v: $out"
done

# the same with the thread functions translated ahead of time, under the page protocol
python3 aot/lift.py $B/mp out/aot/ci-mp.c thread_a thread_b thread_pair >/dev/null
sh aot/build.sh out/aot/ci-mp.c out/aot/ci-mp.so
for v in mp vec rep vecflag repflag vecwait lb; do
    out=$(TSO_VIEWS_PROFILE=none $T run --aot out/aot/ci-mp.so $B/mp $v $N | tail -n 1) || fail "litmus $v, translated: $out"
    ok "litmus $v, translated: $out"
done

# dynamically linked: the cross compiler's x86-64 C library as the root file system
X=/usr/x86_64-linux-gnu
if [ -z "$SKIP_BUILD" ] && [ -f $X/lib/libc.so.6 ]; then
    R=$PWD/$B/rootfs
    mkdir -p $R/lib64 $R/lib
    cp -L $X/lib/ld-linux-x86-64.so.2 $R/lib64/
    cp -L $X/lib/libc.so.6 $X/lib/libm.so.6 $R/lib/
    $CC -O2 -pthread -o $B/threads-dyn tests/threads.c
    out=$(FEX_ROOTFS=$R $T run $B/threads-dyn 20 | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "threads, dynamically linked: $out"
    ok "threads, dynamically linked: $out"
fi

# a ring buffer written for x86 order: every message right with tso-arm (without ordering some may not be)
out=$($T run $B/spsc 20000000) || fail "ring buffer: $out"
ok "ring buffer, tso-arm: $out"
echo "      ring buffer without ordering, for comparison: $($T run --mode unordered $B/spsc 20000000 || true)"
echo "all tests passed"

#!/bin/sh
# Correctness on any Arm machine with tso-arm installed (the CI runs it on GitHub's Arm runners): builds the x86-64
# test programs with a cross compiler, then through `tso-arm run`: the views corner cases (struct fields, a shared
# stack), more threads than view slots, the litmus tests under the page protocol and with translated thread
# functions, and a ring buffer that relies on x86 order. Outputs that need a reference are compared with FEX's own
# full ordering. Exit status 1 on the first failure.
#   tests/ci.sh          CC_X86 (default x86_64-linux-gnu-gcc), CC_X86_32 (default i686-linux-gnu-gcc), ITER (litmus
#                        iterations, default 200000)
set -e
cd "$(dirname "$0")/.."
T=bin/tso-arm
CC=${CC_X86:-x86_64-linux-gnu-gcc}
CC32=${CC_X86_32:-i686-linux-gnu-gcc}
N=${ITER:-200000}
B=build/ci
mkdir -p $B out/aot
fail() {
    echo "FAIL: $*"
    exit 1
}
ok() { echo "ok:   $*"; }
# last COMMAND...: the command's last line of output, and its exit status (a pipe into tail gave tail's, so a test
# program that crashed or reported a failure by its status passed)
last() {
    o=$("$@") && s=0 || s=$?
    printf '%s\n' "$o" | tail -n 1
    return $s
}

if [ -z "$SKIP_BUILD" ]; then # SKIP_BUILD=1: the programs in build/ci were built elsewhere
    $CC -O2 -static -pthread -o $B/mp litmus/mp.c
    $CC -O2 -static -pthread -o $B/threads tests/threads.c
    $CC -O2 -static -pthread -o $B/spsc tests/spsc.c
    $CC -O2 -static -pthread -o $B/wake tests/wake.c
    $CC -O2 -static -pthread -o $B/sharedstack tests/sharedstack.c
    $CC -O2 -static -pthread -o $B/fields study/work/fields.c
    $CC -O2 -static -pthread -o $B/fork tests/fork.c
    $CC -O2 -static -o $B/signals tests/signals.c
    $CC -O2 -static -pthread -o $B/sigrace tests/sigrace.c
    $CC -O2 -static -pthread -o $B/smc tests/smc.c
    $CC -O2 -static -o $B/fdfull tests/fdfull.c
    $CC -O2 -static -pthread -o $B/exactstart tests/exactstart.c
    $CC -O2 -static -pthread -o $B/xmc tests/xmc.c
    $CC -O2 -static -o $B/sigign tests/sigign.c
    $CC -O2 -static -pthread -o $B/faultaddr tests/faultaddr.c
    $CC -O2 -static -pthread -o $B/writeonly tests/writeonly.c
    $CC -O2 -static -pthread -o $B/segload tests/segload.c
    $CC -O2 -static -pthread -o $B/forksnap tests/forksnap.c
    $CC -O2 -static -pthread -o $B/forkeintr tests/forkeintr.c
    $CC -O2 -static -pthread -o $B/lastexit tests/lastexit.c
    $CC -O2 -static -pthread -o $B/singlethread tests/singlethread.c
    $CC -O2 -static -pthread -o $B/userns tests/userns.c
    $CC -O2 -static -pthread -o $B/chrootfs tests/chrootfs.c
    $CC -O2 -static -pthread -o $B/seccompbpf tests/seccompbpf.c
    $CC -O2 -static -pthread -o $B/bigmap tests/bigmap.c
    $CC -O2 -static -o $B/faultrip tests/faultrip.c
    $CC -O2 -static -o $B/closeall tests/closeall.c
    $CC -O2 -static -pthread -o $B/spawnvm tests/spawnvm.c
    $CC -O2 -static -pthread -o $B/rlimitdata tests/rlimitdata.c
    $CC -O2 -static -pthread -o $B/sigregs tests/sigregs.c
    $CC -O2 -static -pthread -o $B/filegrow tests/filegrow.c
    $CC -O2 -static -pthread -o $B/fixedover tests/fixedover.c
    $CC -O2 -static -pthread -o $B/cowmap tests/cowmap.c
    $CC -O2 -static -pthread -o $B/sharedmap tests/sharedmap.c
    $CC -O2 -static -pthread -o $B/preempt tests/preempt.c
    $CC -O2 -static -o $B/sigspin tests/sigspin.c
    $CC -O2 -static -pthread -o $B/sigsync tests/sigsync.c
    $CC -O2 -static -o $B/x87 tests/x87.c
    $CC -O2 -static -o $B/filemap tests/filemap.c
    # 32-bit x86 programs (CC_X86_32, default i686-linux-gnu-gcc; skipped without one)
    if command -v $CC32 >/dev/null; then
        $CC32 -O2 -msse2 -static -pthread -o $B/mp32 litmus/mp32.c
        $CC32 -O2 -static -pthread -o $B/threads32 tests/threads.c
        $CC32 -O2 -static -o $B/vsyscall32 tests/vsyscall32.c
        $CC32 -O2 -static -pthread -o $B/lastexit32 tests/lastexit.c
        $CC32 -O2 -static -pthread -o $B/singlethread32 tests/singlethread.c
    fi
fi
sh tools/board_check.sh | sed 's/^/      /'

# what tso-arm reads of a program without binutils (machine, kind, build ID), against readelf
if command -v readelf >/dev/null; then
    out=$(last sh tests/elfinfo_check.sh $B) || fail "$out"
    ok "$out"
fi

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
out=$(last $T run $B/fork) || fail "$out"
ok "$out"

# private file mappings: a read-only one is mapped from the file itself, and stays private when it is made writable
# (after a fork as well); the file never changes
out=$($T run $B/filemap | tail -n 1)
[ "$out" = "filemap: all right" ] || fail "filemap: $($T run $B/filemap | grep WRONG | head -n 3)"
ok "$out"

# the program's own signal handlers, in every mode
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/signals) || fail "signals, $m: $out"
    ok "$m: $out"
done

# signals ignored across execve, as nohup leaves SIGHUP (FEX began a new process with every signal at its default;
# notes section 53)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/sigign) || fail "sigign, $m: $out"
    ok "$m: $out"
done

# a FEXServer started by a program does not keep that program's stdout: a command substitution ends with the
# program, not with the server (FEX passed all its descriptors on, and go test -exec waited two minutes for its pipe
# while other tests kept the server alive). A server of its own (socket and lock in a new directory).
S=$(mktemp -d)
s=$(date +%s%N)
out=$(env XDG_DATA_HOME=$S FEX_SERVERSOCKETPATH=$S/server.socket $T run --mode full $B/sigign | tail -n 1)
ms=$(( ($(date +%s%N) - s) / 1000000 ))
srv=$(pgrep -n -u "$(id -u)" -x FEXServer)
fd1=$( [ -n "$srv" ] && readlink /proc/$srv/fd/1)
[ $ms -lt 1000 ] && { [ -z "$srv" ] || [ "$fd1" = /dev/null ]; } || fail "FEXServer kept the pipe: $ms ms, its stdout $fd1"
ok "a fresh FEXServer leaves the pipe: $ms ms, its stdout ${fd1:-gone}"
for i in $(seq 50); do [ -n "$srv" ] && kill -0 "$srv" 2>/dev/null || break; sleep 0.1; done
rm -rf "$S"

# the address a fault of the program's own reports, SIGSEGV and SIGBUS, with the views awake (FEX passed on the
# address in the view; Go's runtime took its nil pointer panics for fatal faults; notes section 55)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/faultaddr) || fail "faultaddr, $m: $out"
    ok "$m: $out"
done

# what Wine does and the views took wrongly (notes section 58): memory mapped with PROT_WRITE or PROT_EXEC alone,
# which x86 makes readable, segment register loads, whose descriptor FEX reads from its own memory, and a fork while
# another thread writes, whose child must see memory as it was at the fork
for p in writeonly segload forksnap filegrow fixedover cowmap sharedmap; do
    for m in tso full unordered; do
        out=$(last $T run --mode $m $B/$p) || fail "$p, $m: $out"
        ok "$m: $out"
    done
done
# the same fork after the views fell back to full ordering (one view slot: the second thread has none; no profile,
# which would have the program start without views), whose translated code writes past the views: the other threads
# are held until the child has its copy, and their system calls go on without an EINTR
for p in forksnap forkeintr; do
    out=$(last env TSO_VIEWS_SLOTS=1 TSO_VIEWS_PROFILE=none $T run $B/$p) || fail "$p after the fallback: $out"
    ok "after the fallback: $out"
done
# the process ends with its last thread's exit alone (pthread_exit in main, exit in the other thread; one thread
# ending with exit), also with FEX's disk cache and its writer thread: exit status 7 from that thread
for m in tso full unordered; do
    for a in threads raw; do
        st=0
        out=$(timeout 60 $T run --mode $m $B/lastexit $a 2>&1) || st=$?
        [ $st = 7 ] || fail "lastexit $a, $m: exit status $st (7 expected): $out"
    done
    ok "$m: lastexit: the last thread's exit ends the process"
done

# unshare(CLONE_NEWUSER) with FEX's disk cache on: allowed (or not permitted here), not EINVAL for FEX's writer thread;
# with a second thread of the program's own EINVAL, as natively
for a in "" thread; do
    out=$(timeout 60 $T run $B/userns $a 2>&1) || fail "userns $a: $out"
    ok "$out"
done

# Chromium's sandbox: its zygote's chroot to an empty directory through clone(CLONE_FS | CLONE_VM | CLONE_VFORK |
# CLONE_SETTLS), as the first process of a PID namespace, its check through its old /proc that it is alone, then a
# thread and a fork (a renderer); the fork's child of the page protocol listed the swapped pages through /proc by
# path, read every page instead, and died of SIGSEGV, and the check counted the disk cache's writer thread.
# Needs user namespaces (exit status 2 where they are not allowed: AppArmor without 'tso-arm userns allow').
for m in tso full; do
    for v in "" vm pidns; do
        st=0
        out=$(last timeout 60 $T run --mode $m $B/chrootfs $v) || st=$?
        case $st in
        0) ok "$m: $out" ;;
        2) ok "$m: chrootfs ${v:-plain}: not run, $out" ;;
        *) fail "chrootfs ${v:-plain}, $m: exit status $st: $out" ;;
        esac
    done
done

# seccomp-bpf as Chromium's renderers use it (FEX emulates the filters): the kernel's answers to Chromium's checks, a
# filter for all threads (TSYNC) that makes getpid fail with EPERM, in this thread and in one that ran before
for m in tso full; do
    out=$(last timeout 60 $T run --mode $m $B/seccompbpf) || fail "seccompbpf, $m: $out"
    ok "$m: $out"
done

# mappings larger than the views' window (Chromium reserves 32 GB at its start), made after the fallback outside it:
# written, discarded, forked, unmapped in parts, grown, code in them rewritten, threads counting in them, in every
# mode, alone and with threads running before (the views awake); no profile, so that each run falls back itself
for m in tso full unordered; do
    for a in "" threads; do
        out=$(last env TSO_VIEWS_PROFILE=none timeout 120 $T run --mode $m $B/bigmap $a) || fail "bigmap $a, $m: $out"
        ok "$m: $out${a:+ (threads first)}"
    done
done

# a program that closes every descriptor from 3 up at its start (close_range), with a cold disk cache: FEX's own
# descriptors survive it and none of the cache's stores reaches the program's files (they took all of them, and the
# exit waited a second per store where nothing had those numbers)
for m in tso full; do
    dc=$(mktemp -d)
    st=0
    s=$(date +%s)
    out=$(FEX_DISKCACHE=1 FEX_DISKCACHEPATH=$dc/ FEX_DISKCACHEFILEMAPPING=0 timeout 120 $T run --mode $m $B/closeall 2>&1) || st=$?
    secs=$(($(date +%s) - s))
    rm -rf "$dc"
    [ $st = 0 ] && [ $secs -lt 10 ] || fail "closeall, $m: exit status $st after $secs s: $out"
    ok "$m: $(echo "$out" | tail -n 1)"
done

# posix_spawn (clone with CLONE_VM | CLONE_VFORK) while other threads translate code: the child as a vfork, FEX's
# locks and maps in the parent whole (Slack's renderer hung on them)
for m in tso full; do
    out=$(last timeout 120 $T run --mode $m $B/spawnvm 3) || fail "spawnvm, $m: $out"
    ok "$m: $out"
done

# a program that limits its data (RLIMIT_DATA, Chromium's renderers: 8 GB) below what FEX itself maps, then starts
# threads: the limit is the guest's, kept by FEX and read back, and every thread works (a thread's lookup cache failed
# to map under the host's limit, and Slack's renderer jumped into nothing)
for m in tso full; do
    out=$(last timeout 60 $T run --mode $m $B/rlimitdata) || fail "rlimitdata, $m: $out"
    ok "$m: $out"
done

# the registers a function keeps, across a profiler's signals (SIGPROF every 100 microseconds) that come in during
# translated code, system calls and translation
for m in tso full; do
    out=$(last timeout 60 $T run --mode $m $B/sigregs 4) || fail "sigregs, $m: $out"
    ok "$m: $out"
done

# a fault's instruction pointer in the guest's handler, changed there to a landing pad (V8's WebAssembly traps,
# Java's implicit null checks), in every mode
for m in tso full unordered; do
    out=$(last timeout 60 $T run --mode $m $B/faultrip 2000) || fail "faultrip, $m: $out"
    ok "$m: $out"
done

# a program's own threads in /proc/self/task and no thread of FEX's (its disk cache's writer, on here as it is by
# default): Chromium's zygote forks only when it sees one there
for m in tso full; do
    out=$(timeout 60 $T run --mode $m $B/singlethread 2>&1) || fail "singlethread, $m: $out"
    ok "$m: $(echo "$out" | tr '
' ' ')"
done

# asynchronous signals at an instruction start: a handler that makes the interrupted thread call a routine at the
# interrupted address, as Go's preemption does, many times a second into a loop whose carry runs through it (FEX
# delivered them in the middle of an instruction's translation: wrong results or a crash in every run; notes
# section 54)
for m in tso full unordered; do
    out=$(last env TSO_VIEWS_PROFILE=none $T run --mode $m $B/preempt 5000000 3) || fail "preempt, $m: $out"
    ok "$m: $out"
done

# the numbers of synchronous signals sent by another thread to a running loop: handled, never blocked while they wait
# for an exact point (blocked, the fault that delivers them ended the process; notes section 54)
for m in tso full unordered; do
    out=$(last timeout 120 $T run --mode $m $B/sigsync) || fail "sigsync, $m: $out"
    ok "$m: $out"
    # without pauses: each one comes in while FEX still handles the one before
    out=$(last env SIGSYNC_GAP_US=0 timeout 120 $T run --mode $m $B/sigsync 2000) || fail "sigsync without pauses, $m: $out"
    ok "$m, without pauses: $out"
done

# signals that meet: two at once (the second while FEX still handles the first), and one raised while another
# thread changes its action; FEX without the patches crashes in both (notes section 47)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/sigrace 5000) || fail "sigrace, $m: $out"
    ok "$m: $out"
done

# code rewritten while a second thread runs (the views awake): every call runs the bytes just written, also when
# another thread wrote them (notes section 50)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/smc 2000) || fail "smc, $m: $out"
    ok "$m: $out"
done

# code patched by another thread while this one runs it, two bytes at a time as HotSpot does: FEX without the
# patches translated a mix of old and new bytes and crashed in every run (notes section 52)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/xmc 2000) || fail "xmc, $m: $out"
    ok "$m: $out"
done
# ...and five bytes at a time through a `jmp .`, which FEX's block linker could link to its old translation for good
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/xmc 2000 loop) || fail "xmc loop, $m: $out"
    ok "$m, loop: $out"
done

# a thread sent back to the dispatcher at an instruction start finds the guest registers as they are there (CPython's
# GC list unlink, whose rcx FEX had set to 0 ahead of time; notes section 51)
for m in tso full unordered; do
    out=$(last env TSO_VIEWS_BUDGET=0 TSO_VIEWS_PROFILE=none $T run --mode $m $B/exactstart 1000) || fail "exactstart, $m: $out"
    ok "$m: $out"
done

# fork, vfork and posix_spawn's clone with the program's descriptors nearly or all used up: none of them lost
# (notes section 51)
for m in tso full unordered; do
    out=$(last $T run --mode $m $B/fdfull 5) || fail "fdfull, $m: $out"
    ok "$m: $out"
done

# x87 registers, which FEX addresses in the thread's context: the same results as FEX's full ordering
want=$($T run --mode full $B/x87 | tail -n 1)
got=$($T run $B/x87 | tail -n 1)
[ "$got" = "$want" ] || fail "x87: '$got' against '$want'"
ok "$got"

# litmus tests: no forbidden outcome under the page protocol (mp exits 1 if there was one)
for v in mp vec rep stack stackflag vecflag repflag vecwait lb; do
    out=$(last $T run $B/mp $v $N) || fail "litmus $v: $out"
    ok "litmus $v: $out"
done

# the same with the thread functions translated ahead of time, under the page protocol
python3 aot/lift.py $B/mp out/aot/ci-mp.c thread_a thread_b thread_pair >/dev/null
sh aot/build.sh out/aot/ci-mp.c out/aot/ci-mp.so
for v in mp vec rep vecflag repflag vecwait lb; do
    out=$(last env TSO_VIEWS_PROFILE=none $T run --aot out/aot/ci-mp.so $B/mp $v $N) || fail "litmus $v, translated: $out"
    ok "litmus $v, translated: $out"
done

# a loop that waits for its signal handler, as FEX translates it (the signal comes in at the branch back) and
# translated ahead of time (no such points there: the signal is delivered at once; notes section 54)
python3 aot/lift.py $B/sigspin out/aot/ci-sigspin.c spin >/dev/null
sh aot/build.sh out/aot/ci-sigspin.c out/aot/ci-sigspin.so
out=$(last timeout 120 $T run $B/sigspin) || fail "sigspin: $out"
ok "$out"
out=$(last timeout 120 $T run --aot out/aot/ci-sigspin.so $B/sigspin) || fail "sigspin, translated: $out"
ok "translated: $out"

# dynamically linked: the cross compiler's x86-64 C library as the root file system (or one built elsewhere by
# tests/build_ci_programs.sh)
X=/usr/x86_64-linux-gnu
R=$PWD/$B/rootfs
if [ -z "$SKIP_BUILD" ] && [ -f $X/lib/libc.so.6 ]; then
    mkdir -p $R/lib64 $R/lib
    cp -L $X/lib/ld-linux-x86-64.so.2 $R/lib64/
    cp -L $X/lib/libc.so.6 $X/lib/libm.so.6 $R/lib/
    $CC -O2 -pthread -o $B/threads-dyn tests/threads.c
    $CC -O2 -fPIC -shared -Wl,--build-id -o $R/lib/libhot.so tests/sharedlib/libhot.c
    $CC -O2 -Wl,--build-id -o $B/dl tests/sharedlib/dl.c
fi
if [ -f $R/lib/libc.so.6 ]; then
    # FEX's server keeps the root file system of the client that started it until about a second after its last
    # client: one the tests above started with a machine's default root file system would serve these too (at most
    # 10 s)
    for i in $(seq 50); do
        pgrep -u "$(id -u)" -x FEXServer >/dev/null 2>&1 || break
        sleep 0.2
    done
    out=$(FEX_ROOTFS=$R $T run $B/threads-dyn 20 | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "threads, dynamically linked: $out"
    ok "threads, dynamically linked: $out"

    # a shared library's functions translated ahead of time: FEX takes them from the cache (TSO_AOT_DIR, under the
    # library's name and build ID) when the program maps the library with dlopen, and gives them up at dlclose
    C=$PWD/$B/cache
    rm -rf $C
    mkdir -p $C/tso-arm/aot
    id=$(LC_ALL=C readelf -n $R/lib/libhot.so | sed -n 's/^ *Build ID: *//p' | cut -c1-16)
    python3 aot/lift.py $R/lib/libhot.so out/aot/libhot.c hot_sum mix hot_apply >/dev/null
    sh aot/build.sh out/aot/libhot.c $C/tso-arm/aot/libhot.so-$id.so >/dev/null 2>&1 || fail "shared library: build"
    want=$(FEX_ROOTFS=$R $T run --no-aot $B/dl | tail -n 1)
    case $want in dl:*) ;; *) fail "shared library: $want" ;; esac
    got=$(FEX_ROOTFS=$R XDG_CACHE_HOME=$C TSO_AOT_LOG=1 $T run $B/dl 2>$B/dl.log | tail -n 1)
    [ "$got" = "$want" ] || fail "shared library, translated: '$got' against '$want'"
    loads=$(grep -c 'functions from .*shared library' $B/dl.log || true)
    gone=$(grep -c 'is unmapped' $B/dl.log || true)
    [ "$loads" = 3 ] && [ "$gone" = 3 ] || fail "shared library, translated: $loads loads and $gone unloads, not 3 each"
    ok "$got (the library's translations taken and given up 3 times)"
fi

# a ring buffer written for x86 order: every message right with tso-arm (without ordering some may not be)
out=$($T run $B/spsc 20000000) || fail "ring buffer: $out"
ok "ring buffer, tso-arm: $out"
echo "      ring buffer without ordering, for comparison: $($T run --mode unordered $B/spsc 20000000 || true)"

# the same after a start with one thread: what was translated while the views slept does not run on with two threads
out=$($T run $B/wake 20000000) || fail "ring buffer after one thread: $out"
ok "$out"

# 32-bit x86 programs: FEX orders all of their accesses (the page protocol is for x86-64 programs)
if [ -x $B/mp32 ]; then
    for v in mp vec rep lb; do
        out=$(last $T run $B/mp32 $v $N) || fail "32-bit litmus $v: $out"
        ok "32-bit litmus: $out"
    done
    echo "      32-bit vec without ordering, for comparison: $($T run --mode unordered $B/mp32 vec $N | tail -n 1 || true)"
    out=$($T run $B/threads32 8 | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "32-bit threads: $out"
    ok "32-bit threads 8: $out"
    # a system call through AT_SYSINFO, as i386 C libraries up to glibc 2.35 make every one
    if [ -x $B/vsyscall32 ]; then
        for m in tso full; do
            out=$(last $T run --mode $m $B/vsyscall32) || fail "32-bit vsyscall, $m: $out"
            ok "$m: $out"
        done
    fi
    # the last thread's exit ends a 32-bit process as well (int 0x80 exit)
    if [ -x $B/lastexit32 ]; then
        for a in threads raw; do
            st=0
            out=$(timeout 60 $T run $B/lastexit32 $a 2>&1) || st=$?
            [ $st = 7 ] || fail "32-bit lastexit $a: exit status $st (7 expected): $out"
        done
        ok "32-bit lastexit: the last thread's exit ends the process"
    fi
    if [ -x $B/singlethread32 ]; then
        out=$(timeout 60 $T run $B/singlethread32 2>&1) || fail "32-bit singlethread: $out"
        ok "32-bit: $(echo "$out" | tr '
' ' ')"
    fi
else
    echo "      32-bit programs: not built (no $CC32)"
fi
echo "all tests passed"

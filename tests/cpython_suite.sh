#!/bin/sh
# CPython's own tests of threads, locks, queues, signals, fork and memory maps, run by the x86-64 python3 of the root
# file system under tso-arm and under FEX's full ordering: no test case may fail under tso-arm that passes under full
# ordering. The tests are those of the interpreter's own release (Lib/test of the source release from python.org,
# fetched once into build/cpython-VERSION, where the logs stay: full.log and tso.log, every test case's result in
# full.xml and tso.xml).
#   tests/cpython_suite.sh [TESTS...]     exit status 1 if a test case fails under tso-arm only
# SUITE_TIME: seconds for all tests in one mode (default 7200).
# Needs the root file system `tso-arm rootfs` fetches (or ROOTFS=directory), curl for the first run, and the host's
# python3 to read the test cases' results (without it only whole tests are compared).
set -u
cd "$(dirname "$0")/.."
T=$PWD/bin/tso-arm
if [ -z "${ROOTFS:-}" ]; then
    ROOTFS=$(ls -d "$HOME"/.local/share/fex-emu/RootFS/*/ 2>/dev/null | head -n 1)
fi
ROOTFS=${ROOTFS%/}
PY=$ROOTFS/usr/bin/python3
[ -x "$PY" ] || {
    echo "no x86-64 root file system with python3: 'tso-arm rootfs' fetches one (or set ROOTFS)"
    exit 2
}
export FEX_ROOTFS=$ROOTFS LC_ALL=C
V=$($T run --mode full "$PY" -c 'import platform; print(platform.python_version())' 2>/dev/null)
case $V in
[0-9]*.[0-9]*.[0-9]*) ;;
*) echo "cpython_suite: python3 did not run under tso-arm"; exit 2 ;;
esac
D=$PWD/build/cpython-$V
if [ ! -f "$D/test/libregrtest/__init__.py" ]; then
    mkdir -p "$D"
    curl -fsSL "https://www.python.org/ftp/python/$V/Python-$V.tar.xz" | tar -C "$D" -xJf - "Python-$V/Lib/test" || {
        echo "cpython_suite: the tests of Python $V could not be fetched from python.org"
        exit 2
    }
    mv "$D/Python-$V/Lib/test" "$D/test"
    rm -rf "$D/Python-$V"
fi
tests=${*:-test_threading test_thread test_threading_local test_threadsignals test_queue test_sched test_signal test_fork1 test_wait4 test_mmap test_selectors test_concurrent_futures}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
for m in full tso; do
    s=$(date +%s)
    # the tests of the interpreter's own release come first on the path; one test at a time, each in a process of
    # its own (-j1), with a time limit per test. PYTHONHOME (the interpreter's own prefix) keeps the tests' child
    # interpreters from starting isolated (-I), which would drop the path and have them import the distribution's
    # small test package instead (test_threading's daemon threads then wait forever for a module it lacks)
    # In a session of its own: a test's time limit ends its worker, not the worker's children, and one left behind
    # keeps FEX's server alive, with this root file system for every later FEX program whatever FEX_ROOTFS says.
    # Whatever is left of the session goes afterwards.
    rm -f "$D/$m.xml"
    (cd "$W" && PYTHONHOME=/usr PYTHONPATH="$D" exec setsid timeout ${SUITE_TIME:-7200} $T run --mode $m "$PY" -m test -j1 \
        --timeout 900 --junit-xml "$D/$m.xml" $tests) >"$D/$m.log" 2>&1 &
    p=$!
    wait $p
    e=$?
    pkill -KILL -s $p 2>/dev/null
    echo "$m: exit $e, $(( $(date +%s) - s )) s, $(grep -E '^(Result|== Tests result)' "$D/$m.log" | tail -n 1)"
    {
        # the tests that failed, crashed or ran out of time, from regrtest's summary ("2 tests failed:" and the
        # names indented below) ...
        awk '/^[0-9]+ tests? (failed|crashed|timed out)[^:]*:$/ { f = 1; next } f && /^ +test/ { for (i = 1; i <= NF; i++) print $i; next } { f = 0 }' "$D/$m.log"
        # ... and within them the single test cases that failed or raised (regrtest's JUnit file)
        [ -f "$D/$m.xml" ] && python3 -c '
import sys, xml.etree.ElementTree as ET
for c in ET.parse(sys.argv[1]).iter("testcase"):
    bad = [e.tag for e in c if e.tag in ("failure", "error")]
    if bad:
        print(c.get("name"), bad[0])' "$D/$m.xml" 2>/dev/null
        # no summary at all (the interpreter died, or the time limit): everything counts as failed
        grep -q '^== Tests result' "$D/$m.log" || echo $tests | tr ' ' '\n'
    } | sort -u >"$W/$m.failed"
    [ -s "$W/$m.failed" ] && sed 's/^/  failed under '$m': /' "$W/$m.failed"
done
only=$(comm -13 "$W/full.failed" "$W/tso.failed")
if [ -n "$only" ]; then
    echo "cpython_suite: failed under tso-arm only:"
    echo "$only" | sed 's/^/  /'
    echo "(the logs: $D/full.log and $D/tso.log)"
    exit 1
fi
echo "cpython_suite: $(echo $tests | wc -w) tests, no test case failed under tso-arm that passed under full ordering"

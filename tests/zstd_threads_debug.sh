#!/bin/sh
# Test machine: zstd with many threads in several configurations, to find what breaks (exit status and output).
#   tests/zstd_threads_debug.sh
cd "$(dirname "$0")/.."
F=$HOME/opt/fex-views/bin/FEX
C=$PWD/build
want=$(grep "^zstd " build/expected.md5 | cut -d' ' -f2)
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
L=TSO_AOT=$PWD/out/aot/zstd.so
try() {
    label=$1
    shift
    env "$@" $F build/x86/zstd $T -3 -f -q -c $C/corpus.tar >/dev/shm/zd-out 2>/tmp/zd.err
    rc=$?
    ok=ok
    [ "$(md5sum </dev/shm/zd-out | cut -c1-8)" != "$want" ] && ok=WRONG
    printf '%-34s %-5s exit %3d %s | %s\n' "$label" $T $rc $ok "$(grep -v '^$' /tmp/zd.err | tail -n 1 | cut -c1-110)"
}
for T in -T14 -T16 -T32; do
    try "protocol, translated functions" $P $L
    try "protocol, FEX only" $P
    try "full TSO, translated functions" FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 $L
    try "protocol, translated, log" $P $L TSO_AOT_LOG=1
done
rm -f /dev/shm/zd-out

#!/bin/sh
# Test machine: zstd under the protocol with its translated functions at several thread counts (exit status), then
# the log of one failing run: protocol and translator messages around the crash.
#   tests/zstd_threads_log.sh [THREADS_FOR_LOG]
cd "$(dirname "$0")/.."
F=$HOME/opt/fex-views/bin/FEX
C=$PWD/build
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none TSO_AOT=$PWD/out/aot/zstd.so"
for t in 4 6 8 10 12; do
    env $P $F build/x86/zstd -T$t -3 -f -q -c $C/corpus.tar >/dev/null 2>&1
    echo "-T$t: exit $?"
done
t=${1:-12}
env $P TSO_AOT_LOG=1 TSO_VIEWS_LOG=1 $F build/x86/zstd -T$t -3 -f -q -c $C/corpus.tar 2>/tmp/zl.err >/dev/null
echo "== -T$t: $(grep -c 'patched' /tmp/zl.err) patches, $(grep -c 'fault ' /tmp/zl.err) faults"
grep -n -i 'not ours\|fallback\|full ordering\|keeps faulting\|escalat.*function\|switch\|segmentation\|Caught\|aot: [^pg]' /tmp/zl.err | grep -v 'compiled rip\|guest call' | head -20
echo "== last lines"
grep -v 'compiled rip\|guest call' /tmp/zl.err | tail -n 12 | cut -c1-200

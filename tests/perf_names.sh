#!/bin/sh
# Test machine: whether perf sees FEX's block names (FEX_BLOCKJITNAMING) with the tso-arm build and with upstream
# FEX, block by block, without ordering; the share of samples in named guest blocks.
#   tests/perf_names.sh
cd "$(dirname "$0")/.."
head -c 3000000 build/corpus.tar >/tmp/pn-in.tar
for f in $HOME/opt/fex-views/bin/FEX $HOME/opt/fex/bin/FEX; do
    env FEX_TSOENABLED=0 FEX_BLOCKJITNAMING=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 \
        perf record -q -e cycles:u -o /tmp/pn.data $f build/x86/pigz -n -p 4 -c /tmp/pn-in.tar >/dev/null 2>&1
    named=$(perf report -i /tmp/pn.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep 'pigz+0x' |
        awk '{ s += $1 } END { printf "%.1f", s }')
    echo "$f: $named % of the samples in named pigz blocks"
done
rm -f /tmp/pn-in.tar /tmp/pn.data

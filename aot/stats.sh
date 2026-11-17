#!/bin/sh
# Test machine: the page protocol's statistics for xz (profile kept), without and with the translated functions.
# xz closes stderr before it exits, so the statistics go to a file.
#   aot/stats.sh
cd "$(dirname "$0")/.."
for aot in "" "TSO_AOT=$PWD/out/aot/xz.so"; do
    echo "== ${aot:-no translated functions}"
    rm -f /tmp/aot-stats.txt
    env TSO_VIEWS=1 TSO_VIEWS_STATS=/tmp/aot-stats.txt FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $aot \
        $HOME/opt/fex-views/bin/FEX build/x86/xz -T4 -6 --block-size=2MiB -c build/corpus8.tar >/dev/null 2>&1
    cat /tmp/aot-stats.txt
done

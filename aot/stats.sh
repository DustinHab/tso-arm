#!/bin/sh
# Test machine: the page protocol's statistics for a workload (no profile), without and with its translated
# functions. Some programs close stderr before they exit, so the statistics go to a file.
#   aot/stats.sh [WORKLOAD]
cd "$(dirname "$0")/.."
w=${1:-xz}
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
for aot in "" "TSO_AOT=$PWD/out/aot/$w.so"; do
    echo "== $w ${aot:-no translated functions}"
    rm -f /tmp/aot-stats.txt
    env TSO_VIEWS=1 TSO_VIEWS_PROFILE=none TSO_VIEWS_STATS=/tmp/aot-stats.txt FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $aot \
        timeout 120 $HOME/opt/fex-views/bin/FEX build/x86/$w $args >/dev/null 2>&1
    cat /tmp/aot-stats.txt
done

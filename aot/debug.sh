#!/bin/sh
# Test machine: one logged run of a workload with translated functions under the page protocol, filtered to what goes
# wrong (and the few lines before it).
#   aot/debug.sh WORKLOAD
cd "$(dirname "$0")/.."
w=${1:-pigz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
TSO_VIEWS=1 TSO_VIEWS_LOG=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 TSO_AOT=$PWD/out/aot/$w.so \
    TSO_AOT_LOG=1 timeout 120 $HOME/opt/fex-views/bin/FEX $X/$w $args 2>&1 >/dev/null |
    grep -a -v 'compiled rip' | grep -a -B8 'not ours\|cannot\|keeps\|unreachable\|ERROR\|rror' | cut -c1-240 | tail -n ${TAIL:-30}

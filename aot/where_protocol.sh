#!/bin/sh
# Test machine: where the user cycles of a workload with its translated functions go under the page protocol (with a
# profile from one run before): per binary (translated library, stubs of patched accesses, FEX, its JIT code) and the
# hottest symbols.
#   aot/where_protocol.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/wp-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so"
rm -f /tmp/wp-$w.prof
env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
env $vars TSO_AOT_LOG=1 perf record -q -e cycles:u -o /tmp/wp.data $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>/tmp/wp-err.txt
echo "switched functions: $(grep -c 'ordered from' /tmp/wp-err.txt)"
perf report -i /tmp/wp.data --sort dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 8
perf report -i /tmp/wp.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 14

#!/bin/sh
# Test machine: the string functions and FEX's dispatcher in a workload with its translated functions, without
# ordering and under the page protocol: perf samples of every symbol with mem/str/dispatch-like names, and the
# translated-function table entries of the library.
#   aot/memset_where.sh [WORKLOAD]
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
lib=$PWD/out/aot/$w.so
prof=/tmp/mw-$w.prof
rm -f $prof
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib"
env $P $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
for cfg in off protocol; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) vars="$P" ;;
    esac
    env $vars perf record -q -e cycles:u -o /tmp/mw-$cfg.data $HOME/opt/fex-views/bin/${FEXBIN:-FEX} $X/$w $args >/dev/null 2>&1
    echo "== $cfg"
    perf report -i /tmp/mw-$cfg.data --sort dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 6
    perf report -i /tmp/mw-$cfg.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -i 'mem\|str\|JIT\|FEX ' | head -n 14
done
echo "== library symbols"
nm -D $lib | grep -i 'mem\|dispatch' | head
echo "== GOT slots read by the translated code (memset/memcpy/memmove)"
grep -n 'rld64\|aot_dispatch' out/aot/$w.c | grep -v '^.*//' | head -n 8
grep -c 'aot_dispatch' out/aot/$w.c

#!/bin/sh
# Test machine: where a workload's translated functions spend their cycles when they run ordered throughout (FEX's TSO
# on, no views, as in the protocol's fallback): the hottest instructions of the hottest ordered function, with the
# instruction kinds summed (ldapr, stlr, dmb, plain loads and stores).
#   aot/ordered_hot.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-zstd}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
env FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib perf record -q -e cycles:u -o /tmp/oh.data \
    $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
perf report -i /tmp/oh.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 8
f=$(perf report -i /tmp/oh.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 1 | awk '{ print $NF }')
echo "== $f by instruction kind (share of its samples)"
perf annotate -i /tmp/oh.data --stdio -s $f 2>/dev/null | awk -F: '/^ +[0-9.]+ +: +[0-9a-f]+:/ {
        split($0, a, ":"); p = a[1] + 0; ins = $3; sub(/^[ \t]+/, "", ins); split(ins, b, /[ \t]/); m = b[1]
        k = (m ~ /^ldapr/) ? "ldapr" : (m ~ /^stlr/) ? "stlr" : (m == "dmb") ? "dmb" : (m ~ /^ld/) ? "load" : (m ~ /^st/) ? "store" : "other"
        s[k] += p }
    END { for (k in s) printf "  %6.2f %%  %s\n", s[k], k }' | sort -rn

#!/bin/sh
# Test machine: the accesses of translated code that the page protocol patched to ordered stubs in one run (with a
# profile), by function of the library.
#   aot/patched.sh [WORKLOAD]
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
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/pa-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib \
    TSO_AOT_LOG=1 $HOME/opt/fex-views/bin/FEX $X/$w $args 2>/tmp/pa-err.txt >/dev/null
nm -n $lib | awk '$2 ~ /^[tT]$/ { print $1, $3 }' >/tmp/pa-syms.txt
grep -o 'patched [a-z]* at library+0x[0-9a-f]*' /tmp/pa-err.txt | while read p kind at off; do
    o=$((${off#library+}))
    awk -v o=$o -v k=$kind 'function h(s,   i, v) { v = 0; for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return v }
        { if (h($1) <= o) f = $2 } END { print k, f }' /tmp/pa-syms.txt
done | sort | uniq -c | sort -rn

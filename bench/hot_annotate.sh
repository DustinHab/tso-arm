#!/bin/sh
# Where in one translated block the cycles go: profile samples matched to its instructions.
# FEX without ordering and without view arithmetic (identity, no rewriting, no exact starts: FEX's own code).
#   bench/hot_annotate.sh WORKLOAD RIP [TOP]      -> out/hot-<rip>.txt (instructions with sample counts)
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=$1
rip=$2
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
mkdir -p out
rm -f /tmp/tso-block-$rip.bin /tmp/tso-block-$rip.addr
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
env TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 TSO_VIEWS_NOEXACT=1 FEX_TSOENABLED=0 \
    TSO_VIEWS_DUMP=$rip perf record -q -e cycles:u -o /tmp/hot.data $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>/dev/null
base=$(cat /tmp/tso-block-$rip.addr)
objdump -D -b binary -m aarch64 /tmp/tso-block-$rip.bin | sed -n '/<.data>:/,$p' | grep -E '^ +[0-9a-f]+:' >/tmp/hot.s
perf script -i /tmp/hot.data -F ip 2>/dev/null | awk -v base=$base '
  function hex(s,   i, c, v) { v = 0; s = tolower(s); for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c } return v }
  BEGIN { b = hex(base) } { o = hex($1) - b; if (o >= 0 && o < 4000000) n[o]++; t++ } END { for (o in n) printf "%x %d\n", o, n[o]; printf "total %d\n", t > "/tmp/hot.total" }' >/tmp/hot.counts
awk 'NR == FNR { c[$1] = $2; next } { off = $1; sub(":", "", off); printf "%6d  %s\n", c[off] + 0, $0 }' /tmp/hot.counts /tmp/hot.s >out/hot-$rip.txt
in=$(awk '{ s += $2 } END { print s }' /tmp/hot.counts)
echo "samples in the block: $in of $(cut -d' ' -f2 /tmp/hot.total)"
echo "hottest instructions:"
sort -rn out/hot-$rip.txt | head -n ${3:-30}

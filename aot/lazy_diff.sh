#!/bin/sh
# Test machine: runs of a workload with its translated functions under the page protocol with TSO_VIEWS_LOG=1 until
# one with many and one with few ranges mapped into a view on first use turn up; prints for both the ranges each
# slot mapped late (with the size and creating slot of the range from the mmap log) and the page shares by range.
#   aot/lazy_diff.sh [WORKLOAD] [RUNS]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
n=${2:-10}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/bm-$w.prof
[ -f $prof ] || { echo "no profile $prof (aot/bimodal.sh writes it)"; exit 1; }
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib FEX_DISABLETELEMETRY=1"
[ -n "$REUSE" ] || for i in $(seq $n); do
    env $P TSO_VIEWS_LOG=1 $HOME/opt/fex-views/bin/FEX $X/$w $args 2>/tmp/ld-$i.log >/dev/null
    grep -v 'compiled rip' /tmp/ld-$i.log >/tmp/ld-$i.txt
    rm -f /tmp/ld-$i.log
    echo "run $i: $(grep -c 'into the views' /tmp/ld-$i.txt) late ranges, $(grep -c 'fault ' /tmp/ld-$i.txt) faults"
done
hi=$(for i in $(seq $n); do echo "$(grep -c 'into the views' /tmp/ld-$i.txt) $i"; done | sort -n | tail -n 1 | cut -d' ' -f2)
lo=$(for i in $(seq $n); do echo "$(grep -c 'into the views' /tmp/ld-$i.txt) $i"; done | sort -n | head -n 1 | cut -d' ' -f2)
for i in $hi $lo; do
    echo "== run $i: late ranges by size (count)"
    grep 'into the views' /tmp/ld-$i.txt | python3 -c '
import sys, collections
c = collections.Counter()
for l in sys.stdin:
    a, b = l.split()[2].split("-")
    c[(int(b, 16) - int(a, 16)) // 1024] += 1
for k in sorted(c): print(f"  {k} KB: {c[k]}")'
    echo "== run $i: faults by kind"
    grep 'tso-arm: fault ' /tmp/ld-$i.txt | grep -o 'escalate\|retry\|not ours: [a-z ]*' | sort | uniq -c
    echo "== run $i: mmaps by slot (count, total MB)"
    grep 'tso-arm: mmap' /tmp/ld-$i.txt | python3 -c '
import sys, collections
c = collections.Counter(); s = collections.Counter()
for l in sys.stdin:
    p = l.split()
    a, ln = p[2].split("+")
    slot = p[-1]
    c[slot] += 1; s[slot] += int(ln, 16)
for k in sorted(c): print(f"  slot {k}: {c[k]} mmaps, {s[k] / 2**20:.1f} MB")'
done
echo "== late ranges only in run $hi"
grep 'into the views' /tmp/ld-$hi.txt | awk '{ print $3, $NF }' | sort >/tmp/ld-a
grep 'into the views' /tmp/ld-$lo.txt | awk '{ print $3, $NF }' | sort >/tmp/ld-b
comm -23 /tmp/ld-a /tmp/ld-b
echo "== only in run $lo"
comm -13 /tmp/ld-a /tmp/ld-b

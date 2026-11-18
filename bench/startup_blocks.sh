#!/bin/sh
# Test machine: which guest functions FEX compiles blocks for during a workload's start-up (empty input, translated
# library, page protocol): blocks per function from TSO_VIEWS_LOG's compile lines and the x86 binary's symbols.
#   bench/startup_blocks.sh [WORKLOAD] [INPUT]      INPUT: empty (default) or full
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) full="-T4 -3 -f -q -c $C/corpus.tar" empty="-T4 -3 -f -q -c /dev/null" ;;
pigz) full="-n -p 4 -c $C/corpus.tar" empty="-n -p 4 -c /dev/null" ;;
xz) full="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" empty="-T4 -6 -c /dev/null" ;;
esac
[ "${2:-empty}" = full ] && args=$full || args=$empty
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$HOME/.cache/tso-arm/$w-aot.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so FEX_DISABLETELEMETRY=1"
env $P TSO_VIEWS_LOG=1 $HOME/opt/fex-views/bin/FEX $X/$w $args 2>&1 >/dev/null | grep 'compiled rip' |
    sed 's/.*compiled rip \(0x[0-9a-f]*\).*/\1/' >/tmp/sb-rips.txt
nm -n $X/$w | awk '$2 ~ /^[tTwWiI]$/ { print $1, $3 }' >/tmp/sb-syms.txt
python3 - <<'EOF'
import bisect, collections
addrs, names = [], []
for l in open("/tmp/sb-syms.txt"):
    a, n = l.split()
    addrs.append(int(a, 16)); names.append(n)
c = collections.Counter()
rips = [int(l, 16) for l in open("/tmp/sb-rips.txt") if l.strip()]
for r in rips:
    i = bisect.bisect_right(addrs, r) - 1
    c[names[i] if i >= 0 else "?"] += 1
print(f"{len(rips)} blocks in {len(c)} functions")
acc = 0
for n, k in c.most_common(40):
    acc += k
    print(f"  {k:5d}  {acc * 100 // len(rips):3d} %  {n}")
EOF

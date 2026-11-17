#!/bin/sh
# Test machine: which patched accesses (stubs) of a workload's translated code are hot under the page protocol: one
# profiled run (with a profile from a run before) that also logs its patches, stub samples joined to the patched
# instruction, its function and kind.
#   aot/hot_stubs.sh [WORKLOAD]
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
vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/hs-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib"
rm -f /tmp/hs-$w.prof
env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
env $vars TSO_AOT_LOG=1 perf record -q -e cycles:u -o /tmp/hs.data $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>/tmp/hs-err.txt
nm -n $lib | awk '$2 ~ /^[tT]$/ { print $1, $3 }' >/tmp/hs-syms.txt
perf report -i /tmp/hs.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | awk '$NF ~ /^0x/ { print $1, $NF }' >/tmp/hs-samples.txt
objdump -d $lib --no-show-raw-insn >/tmp/hs-lib.s 2>/dev/null
python3 - <<'EOF'
import bisect, re
syms = [(int(a, 16), n) for a, n in (l.split() for l in open("/tmp/hs-syms.txt"))]
starts = [a for a, n in syms]
stubs = []
for l in open("/tmp/hs-err.txt"):
    m = re.search(r"patched (\w+) at library\+(0x[0-9a-f]+) \(stub (0x[0-9a-f]+)\)", l)
    if m:
        stubs.append((int(m.group(3), 16), m.group(1), int(m.group(2), 16)))
stubs.sort()
code = {}
for l in open("/tmp/hs-lib.s"):
    m = re.match(r"\s+([0-9a-f]+):\s+(.*)", l)
    if m:
        code[int(m.group(1), 16)] = m.group(2).strip()
total = {}
for l in open("/tmp/hs-samples.txt"):
    p, a = l.split()
    a = int(a, 16)
    k = bisect.bisect_right([s[0] for s in stubs], a) - 1
    if k >= 0 and a < stubs[k][0] + 0x50:
        s = stubs[k]
        total[s] = total.get(s, 0) + float(p.rstrip("%"))
print(f"{len(stubs)} patched accesses; hot stubs (share of all cycles):")
for s, p in sorted(total.items(), key=lambda x: -x[1])[:15]:
    f = syms[bisect.bisect_right(starts, s[2]) - 1][1]
    print(f"  {p:5.2f} %  {s[1]:5s} {f}+{s[2] - syms[bisect.bisect_right(starts, s[2]) - 1][0]:#x}: {code.get(s[2], '?')}")
print(f"  {sum(total.values()):5.2f} %  all stubs")
EOF

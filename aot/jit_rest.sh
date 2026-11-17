#!/bin/sh
# Test machine: what FEX still translates and runs when a workload's hot functions are translated ahead of time
# (page protocol, profile from a run before): JIT cycles per guest function.
#   aot/jit_rest.sh [WORKLOAD]
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
vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=/tmp/jr-$w.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so"
rm -f /tmp/jr-$w.prof
env $vars $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
env $vars FEX_BLOCKJITNAMING=1 perf record -q -e cycles:u -o /tmp/jr.data $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
nm -n $X/$w | awk '$2 ~ /^[tTwW]$/ { print $1, $3 }' >/tmp/jr-syms.txt
perf report -i /tmp/jr.data --sort dso,sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' >/tmp/jr.txt
python3 - "$X/$w" "$w" <<'EOF'
import bisect, re, subprocess, sys
binary, w = sys.argv[1], sys.argv[2]
base = None
for l in subprocess.run(["readelf", "-lW", binary], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if p and p[0] == "LOAD":
        base = int(p[2], 16)
        break
addrs, names = [], []
for l in open("/tmp/jr-syms.txt"):
    a, n = l.split()
    addrs.append(int(a, 16))
    names.append(n)
share = {}
pat = re.compile(re.escape(w) + r"\+0x([0-9a-f]+)")
anon = re.compile(r"JIT_0x([0-9a-f]+)_")
for l in open("/tmp/jr.txt"):
    p = float(l.split()[0].rstrip("%"))
    m = pat.search(l)
    a = anon.search(l)
    if m:
        f = "guest " + names[bisect.bisect_right(addrs, base + int(m.group(1), 16)) - 1]
    elif a:
        rip = int(a.group(1), 16)
        f = ("guest " + names[bisect.bisect_right(addrs, rip) - 1]) if addrs[0] <= rip < addrs[-1] + 0x10000 else f"guest code {rip:#x} (no file)"
    else:
        f = l.split()[1] + " " + l.split()[-1][:30]
    share[f] = share.get(f, 0) + p
for f, p in sorted(share.items(), key=lambda x: -x[1])[:16]:
    print(f"  {p:6.2f} %  {f}")
EOF

#!/bin/sh
# Cycles per function, native Arm build against FEX without ordering (guest functions from the x86-64 build's
# symbol table, FEX naming its blocks "<file>+<offset>"). Prints both sides with the share of all user cycles.
#   bench/func_profile.sh [workload]      TOP=n rows (default 20)
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
w=${1:-xz}
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done; }

cool
perf record -q -e cycles:u -o /tmp/fp-native.data $N/$w $args >/dev/null 2>&1
echo "native $w:"
perf report -i /tmp/fp-native.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' |
    awk '{ sub(/%/, "", $1); printf "  %6.2f %%  %s\n", $1, $NF }' | head -n ${TOP:-20}

cool
env FEX_TSOENABLED=0 FEX_BLOCKJITNAMING=1 perf record -q -e cycles:u -o /tmp/fp-fex.data \
    $HOME/opt/fex/bin/FEX $X/$w $args >/dev/null 2>&1
nm -n $X/$w | awk '$2 ~ /^[tTwW]$/ { print $1, $3 }' >/tmp/fp-syms.txt
echo "FEX (no ordering) $w:"
perf report -i /tmp/fp-fex.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' >/tmp/fp-fex.txt
python3 - "$X/$w" "$w" <<'EOF' | head -n ${TOP:-20}
import bisect, re, subprocess, sys
binary, w = sys.argv[1], sys.argv[2]
# load base of the (static, non-PIE) guest binary: the lowest PT_LOAD address
base = None
for l in subprocess.run(["readelf", "-lW", binary], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if p and p[0] == "LOAD":
        base = int(p[2], 16)
        break
addrs, names = [], []
for l in open("/tmp/fp-syms.txt"):
    a, n = l.split()
    addrs.append(int(a, 16))
    names.append(n)
share = {}
pat = re.compile(re.escape(w) + r"\+0x([0-9a-f]+)")
for l in open("/tmp/fp-fex.txt"):
    p = float(l.split()[0].rstrip("%"))
    m = pat.search(l)
    if m:
        rip = base + int(m.group(1), 16)
        f = names[bisect.bisect_right(addrs, rip) - 1]
    elif "Dispatch_" in l:
        f = "(dispatcher)"
    else:
        f = "(other: " + l.split()[-1][:40] + ")"
    share[f] = share.get(f, 0) + p
for f, p in sorted(share.items(), key=lambda x: -x[1]):
    print(f"  {p:6.2f} %  {f}")
EOF

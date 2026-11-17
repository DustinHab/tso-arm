#!/bin/sh
# Test machine: instructions the page protocol escalates in xz (FEX, no translated functions), per guest function:
# from the profile one fresh run leaves behind.
#   aot/esc_funcs.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
C=$PWD/build
rm -f $HOME/.cache/tso-arm/xz-*.prof
env TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX $X/xz -T4 -6 --block-size=2MiB \
    -c $C/corpus8.tar >/dev/null 2>&1
prof=$(ls $HOME/.cache/tso-arm/xz-*.prof | head -n 1)
nm -n $X/xz | awk '$2 ~ /^[tTwW]$/ { print $1, $3 }' >/tmp/ef-syms.txt
python3 - "$prof" <<'EOF'
import bisect, sys
addrs, names = [], []
for l in open("/tmp/ef-syms.txt"):
    a, n = l.split()
    addrs.append(int(a, 16))
    names.append(n)
count = {}
fallback = False
for l in open(sys.argv[1]):
    p = l.split()
    if p and p[0] == "esc":
        s = int(p[1], 16)
        f = names[bisect.bisect_right(addrs, s) - 1]
        count[f] = count.get(f, 0) + 1
    elif p and p[0] == "fallback":
        fallback = True
print("fallback" if fallback else "no fallback", "-", sum(count.values()), "escalated instructions")
for f, n in sorted(count.items(), key=lambda x: -x[1])[:30]:
    print(f"  {n:5d}  {f}")
EOF

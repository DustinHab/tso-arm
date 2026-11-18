#!/bin/sh
# Test machine: user cycles per function, the native Arm build against the translated library without ordering and
# under the page protocol (fixed clock, one run each): how much slower the translated code itself is.
#   aot/vs_native.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=$HOME/.cache/tso-arm/$w-aot.prof
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
cool() { while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done; }
for cfg in native off protocol; do
    case $cfg in
    native) cmd="$N/$w" vars="X=1" ;;
    off) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    esac
    cool
    env $vars perf record -q -e cycles:u -o /tmp/vn-$cfg.data $cmd $args >/dev/null 2>&1
    perf report -i /tmp/vn-$cfg.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' >/tmp/vn-$cfg.txt
    total=$(perf report -i /tmp/vn-$cfg.data --stdio 2>/dev/null | awk '/Event count/ { print $NF }')
    echo "$total" >/tmp/vn-$cfg.total
done
python3 - <<'EOF'
import re
rows = {}
tot = {}
for cfg in ("native", "off", "protocol"):
    t = int(open(f"/tmp/vn-{cfg}.total").read().strip() or 0)
    tot[cfg] = t
    for l in open(f"/tmp/vn-{cfg}.txt"):
        p = l.split()
        if len(p) < 3:
            continue
        share = float(p[0].rstrip("%"))
        name = p[-1]
        name = re.sub(r"^[fo]_", "", name)
        rows.setdefault(name, {}).setdefault(cfg, 0.0)
        rows[name][cfg] += share * t / 100 / 1e9
print(f"total user cycles (G): native {tot['native']/1e9:.3f}  off {tot['off']/1e9:.3f}  protocol {tot['protocol']/1e9:.3f}")
print(f"{'function':36} {'native':>8} {'off':>8} {'protocol':>8} {'off/nat':>8}")
for name, r in sorted(rows.items(), key=lambda x: -x[1].get("native", 0))[:16]:
    n, o, p = r.get("native", 0), r.get("off", 0), r.get("protocol", 0)
    print(f"{name[:36]:36} {n:8.3f} {o:8.3f} {p:8.3f} {o / n if n else 0:8.2f}")
EOF

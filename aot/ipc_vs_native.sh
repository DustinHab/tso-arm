#!/bin/sh
# Test machine: user cycles and instructions per function, native build against the translation without ordering
# (fixed clock, one run each): whether translated code executes more instructions or the same ones more slowly.
#   aot/ipc_vs_native.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
for cfg in native off; do
    case $cfg in
    native) cmd="$N/$w" vars="X=1" ;;
    off) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_AOT=$PWD/out/aot/$w.so" ;;
    esac
    while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
    for ev in cycles instructions; do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 60 ]; do sleep 5; done
        env $vars perf record -q -e $ev:u -o /tmp/iv-$cfg.data $cmd $args >/dev/null 2>&1
        perf report -i /tmp/iv-$cfg.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' >/tmp/iv-$cfg-$ev.txt
        perf report -i /tmp/iv-$cfg.data --stdio 2>/dev/null | awk '/Event count/ { print $NF; exit }' >/tmp/iv-$cfg-$ev.total
    done
done
python3 - <<'EOF'
import re
def load(cfg, ev):
    t = int(open(f"/tmp/iv-{cfg}-{ev}.total").read().strip() or 0)
    d = {}
    for l in open(f"/tmp/iv-{cfg}-{ev}.txt"):
        p = l.split()
        if len(p) < 3:
            continue
        n = re.sub(r"^[fo]_", "", p[-1])
        d[n] = d.get(n, 0) + float(p[0].rstrip("%")) * t / 100 / 1e9
    return d, t
nc, tnc = load("native", "cycles"); ni, tni = load("native", "instructions")
oc, toc = load("off", "cycles"); oi, toi = load("off", "instructions")
print(f"total: native {tnc/1e9:.3f} G cycles {tni/1e9:.3f} G instr; translated {toc/1e9:.3f} G cycles {toi/1e9:.3f} G instr")
print(f"{'function':34} {'cyc nat':>8} {'cyc tr':>8} {'ins nat':>8} {'ins tr':>8} {'IPC nat':>7} {'IPC tr':>7}")
for n in sorted(nc, key=lambda k: -nc[k])[:12]:
    a, b, c, d = nc.get(n, 0), oc.get(n, 0), ni.get(n, 0), oi.get(n, 0)
    print(f"{n[:34]:34} {a:8.3f} {b:8.3f} {c:8.3f} {d:8.3f} {c / a if a else 0:7.2f} {d / b if b else 0:7.2f}")
EOF

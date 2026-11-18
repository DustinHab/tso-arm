#!/bin/sh
# Test machine: what FEX does in the start-up of a workload with its translated functions (empty input, page protocol
# with the efficiency profile, no telemetry): user/system time and blocks compiled of one run, then the user cycles of
# 20 runs by function, with FEX linked with its symbols (fex/link_symbols.sh).
#   bench/startup_profile.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-pigz}
X=$PWD/build/x86
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
F=$HOME/opt/fex-views/bin/FEX-sym # fex/link_symbols.sh
file $F | grep -o 'not stripped\|, stripped'
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$HOME/.cache/tso-arm/$w-aot.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$PWD/out/aot/$w.so FEX_DISABLETELEMETRY=1"
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
rm -f /tmp/sp-stats.txt
env $P TSO_VIEWS_STATS=/tmp/sp-stats.txt /usr/bin/time -f 'user %U s, sys %S s, wall %e s, %F major/%R minor faults' $F $X/$w $args >/dev/null
cat /tmp/sp-stats.txt | head -n 20
cat >/tmp/sp-loop.sh <<EOF
for i in \$(seq 20); do env $P $F $X/$w $args >/dev/null 2>&1; done
EOF
perf record -q -e cycles:u -o /tmp/sp.data sh /tmp/sp-loop.sh >/dev/null 2>&1
echo "== user cycles of 20 runs by binary"
perf report -i /tmp/sp.data --sort dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 8
echo "== by function"
perf report -i /tmp/sp.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 45 | cut -c1-150
echo "== by caller chain of the top FEX functions (children)"
perf record -q -g -e cycles:u -o /tmp/sp-g.data sh /tmp/sp-loop.sh >/dev/null 2>&1
perf report -i /tmp/sp-g.data --children --sort sym --stdio -g none 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 45 | cut -c1-150

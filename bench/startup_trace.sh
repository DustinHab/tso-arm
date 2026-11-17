#!/bin/sh
# Test machine: where FEX's start-up waits. One run of a workload on an empty input under strace (all threads,
# time spent in each call), the slowest calls and the time between the first and the last call.
#   bench/startup_trace.sh [WORKLOAD]
cd "$(dirname "$0")/.."
w=${1:-zstd}
X=$PWD/build/x86
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
env FEX_TSOENABLED=0 strace -f -tt -T -o /tmp/st.txt $HOME/opt/fex/bin/FEX $X/$w $args >/dev/null 2>&1
echo "calls: $(wc -l </tmp/st.txt), first $(head -1 /tmp/st.txt | awk '{print $2}'), last $(tail -1 /tmp/st.txt | awk '{print $2}')"
echo "slowest:"
awk -F'<' 'NF > 1 { t = $NF; sub(/>.*/, "", t); print t, $0 }' /tmp/st.txt | sort -rn | head -n 12 | cut -c1-160
echo "by call (count, total s):"
awk -F'<' 'NF > 1 { t = $NF; sub(/>.*/, "", t); split($1, a, " "); c = a[3]; sub(/\(.*/, "", c); n[c]++; s[c] += t } END { for (c in n) printf "%8.4f %5d %s\n", s[c], n[c], c }' /tmp/st.txt | sort -rn | head -n 12

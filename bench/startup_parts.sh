#!/bin/sh
# Test machine: what FEX's fixed cost per process consists of, for a workload on an empty input: wall time, CPU time,
# blocks compiled and the time spent compiling them (page protocol statistics), and the same with FEX's code cache.
#   bench/startup_parts.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-zstd}
X=$PWD/build/x86
case $w in
zstd) args="-T4 -3 -f -q -c /dev/null" ;;
pigz) args="-n -p 4 -c /dev/null" ;;
xz) args="-T4 -6 -c /dev/null" ;;
esac
V="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1"
for cfg in plain cache; do
    vars="$V"
    [ $cfg = cache ] && vars="$V FEX_ENABLECODECACHINGWIP=1"
    for i in 1 2 3; do
        rm -f /tmp/su-stats.txt
        s=$(date +%s%N)
        env $vars TSO_VIEWS_STATS=/tmp/su-stats.txt /usr/bin/time -f '%U %S' -o /tmp/su-time.txt $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
        e=$(date +%s%N)
        printf '%-6s run %d: wall %5.1f ms, user/sys %s s, %s\n' $cfg $i "$(echo "($e - $s) / 1000000" | bc -l)" "$(cat /tmp/su-time.txt)" \
            "$(grep -o 'block compiles.*' /tmp/su-stats.txt)"
    done
done

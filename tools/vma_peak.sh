#!/bin/sh
# Peak number of memory mappings (VMAs) of a program under the page protocol, sampled every 20 ms.
#   tools/vma_peak.sh program args...
cd "$(dirname "$0")/.."
echo "max_map_count $(cat /proc/sys/vm/max_map_count)"
env TSO_VIEWS=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX "$@" >/dev/null 2>/tmp/vma.err &
pid=$!
peak=0
while kill -0 $pid 2>/dev/null; do
    n=$(wc -l </proc/$pid/maps 2>/dev/null || echo 0)
    [ "$n" -gt "$peak" ] && peak=$n
    sleep 0.02
done
wait $pid
echo "exit $? peak VMAs $peak"
grep 'claims' /tmp/vma.err

#!/bin/sh
# Test machine: after a failed aot/try.sh run, the end of its log and the library code around the last patched sites
# (function and instructions).
#   aot/crash_site.sh WORKLOAD [SITES]
cd "$(dirname "$0")/.."
w=$1
n=${2:-3}
lib=out/aot/$w.so
echo "== end of the log"
grep -v 'patched' /tmp/aot-err.txt | tail -n 15
for off in $(grep -o 'library+0x[0-9a-f]*' /tmp/aot-err.txt | tail -n $n | cut -d+ -f2); do
    s=$(printf '%d' $off)
    echo "== site $off"
    objdump -d --no-show-raw-insn --start-address=$((s - 24)) --stop-address=$((s + 12)) $lib | grep -E '^ *[0-9a-f]+:|>:' | tail -n 10
done

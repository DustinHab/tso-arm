#!/bin/sh
# Test machine: which patched site makes a workload go wrong under the page protocol. One run with every load on the
# barrier path (TSO_AOT_NOFAST=1), then a binary search over TSO_AOT_PATCH_MAX (sites patched before functions
# switch instead); prints the last site patched in the first failing run of the smallest failing count.
#   aot/patch_bisect.sh WORKLOAD [FUNCTION]
cd "$(dirname "$0")/.."
w=$1
only=${2:+TSO_AOT_ONLY=$2}
run() {
    AOT_ENV="$only $*" sh aot/try.sh $w protocol 2>/dev/null | head -n 1
}
echo "nofast:     $(run TSO_AOT_NOFAST=1)"
echo "all:        $(run)"
lo=0
hi=$(grep -c 'patched' /tmp/aot-err.txt)
echo "sites patched in the full run: $hi"
while [ $((hi - lo)) -gt 1 ]; do
    mid=$(((lo + hi) / 2))
    r=$(run TSO_AOT_PATCH_MAX=$mid)
    echo "max $mid: $r"
    case "$r" in *", ok"*) lo=$mid ;; *) hi=$mid ;; esac
done
r=$(run TSO_AOT_PATCH_MAX=$hi)
echo "smallest failing count $hi: $r; its last patch:"
grep 'patched' /tmp/aot-err.txt | tail -n 1
off=$(grep -o 'library+0x[0-9a-f]*' /tmp/aot-err.txt | tail -n 1 | cut -d+ -f2)
s=$(printf '%d' $off)
objdump -d --no-show-raw-insn --start-address=$((s - 40)) --stop-address=$((s + 24)) out/aot/$w.so | grep -E '^ *[0-9a-f]+:|>:'

#!/bin/sh
# Disassembles an x86-64 binary around guest addresses (WSL). Usage: tools/guestdis.sh BINARY ADDR [ADDR...]
B=$1
shift
for a in "$@"; do
    s=$(printf '0x%x' $((a - 0x30)))
    e=$(printf '0x%x' $((a + 0x20)))
    echo "== $a $(addr2line -f -e "$B" "$a" | head -n 1)"
    objdump -d --no-show-raw-insn --start-address="$s" --stop-address="$e" "$B" | grep -E '^ +[0-9a-f]+:'
done

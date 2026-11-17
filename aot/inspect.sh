#!/bin/sh
# WSL: one function of an x86-64 binary: size, calls it makes, mnemonics it uses.
#   aot/inspect.sh BINARY FUNCTION
B=$1
F=$2
range=$(nm -S "$B" | awk -v f="$F" '$4 == f { print $1, $2 }')
start=$((0x$(echo $range | cut -d' ' -f1)))
size=$((0x$(echo $range | cut -d' ' -f2)))
printf 'function %s at %#x, %d bytes\n' "$F" $start $size
objdump -d --no-show-raw-insn --start-address=$start --stop-address=$((start + size)) "$B" | grep -E '^ +[0-9a-f]+:' >/tmp/fn.s
echo "instructions: $(wc -l </tmp/fn.s)"
echo "calls and indirect jumps:"
grep -E '\scall|jmp +\*' /tmp/fn.s | sed 's/^ *[0-9a-f]*:\s*//' | sort | uniq -c | sort -rn | head -20
echo "mnemonics:"
awk -F'\t' '{ split($2, a, " "); print a[1] }' /tmp/fn.s | sort | uniq -c | sort -rn | awk '{ printf "%s:%s ", $2, $1 } END { print "" }'

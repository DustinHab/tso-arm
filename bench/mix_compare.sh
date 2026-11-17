#!/bin/sh
# Instruction mix of one function: native Arm build against FEX's translation of the x86-64 build (dumped block,
# bench/dump_block.sh, its "nopass" variant = FEX's own code generation).
#   bench/mix_compare.sh WORKLOAD FUNCTION RIP
cd "$(dirname "$0")/.."
w=$1 fn=$2 rip=$3
objdump -d --no-show-raw-insn build/arm64/$w | awk -v f="<$fn>:" '$2 == f { on = 1; next } on && /^$/ { exit } on { print }' |
    grep -E '^ +[0-9a-f]+:' | cut -f2- | awk '{print $1}' | sort | uniq -c | sort -rn >/tmp/mix-native.txt
awk '{print $1}' out/block-$rip-nopass.s | sort | uniq -c | sort -rn >/tmp/mix-fex.txt
printf 'native %s: %d instructions; FEX block: %d instructions\n' $fn "$(awk '{s += $1} END {print s}' /tmp/mix-native.txt)" \
    "$(awk '{s += $1} END {print s}' /tmp/mix-fex.txt)"
join -1 2 -2 2 -a 1 -a 2 -e 0 -o 0,1.1,2.1 <(sort -k2 /tmp/mix-native.txt) <(sort -k2 /tmp/mix-fex.txt) 2>/dev/null |
    sort -k3 -rn | head -n 25 | awk '{ printf "  %-8s native %5d  fex %5d\n", $1, $2, $3 }'

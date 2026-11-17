#!/bin/sh
# WSL: the functions of an x86-64 binary reachable from a root through direct calls, with size and the indirect calls
# each makes. Stops at the functions named in STOP (space separated).
#   aot/calls.sh BINARY ROOT
B=$1
ROOT=$2
nm -S -n "$B" | awk 'NF == 4 && $3 ~ /^[tTwW]$/ { print $1, $2, $4 }' >/tmp/calls-syms.txt
todo=$ROOT
seen=" "
while [ -n "$todo" ]; do
    set -- $todo
    f=$1
    shift
    todo=$*
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    line=$(awk -v f="$f" '$3 == f { print; exit }' /tmp/calls-syms.txt)
    [ -z "$line" ] && { echo "$f: no symbol"; continue; }
    start=$((0x$(echo $line | cut -d' ' -f1)))
    size=$((0x$(echo $line | cut -d' ' -f2)))
    objdump -d --no-show-raw-insn --start-address=$start --stop-address=$((start + size)) "$B" | grep -E '^ +[0-9a-f]+:' >/tmp/calls-fn.s
    n=$(wc -l </tmp/calls-fn.s)
    direct=$(grep -E '\scall +[0-9a-f]+ <' /tmp/calls-fn.s | sed 's/.*<\(.*\)>.*/\1/' | sort -u | tr '\n' ' ')
    tails=$(grep -E '\sjmp +[0-9a-f]+ <' /tmp/calls-fn.s | sed 's/.*<\(.*\)>.*/\1/' | grep -v '+' | sort -u | tr '\n' ' ')
    indirect=$(grep -cE '\s(call|jmp) +\*' /tmp/calls-fn.s)
    printf '%-32s %#x %5d bytes %5d insns  indirect %s\n    calls: %s\n' "$f" $start $size $n $indirect "$direct"
    [ -n "$tails" ] && printf '    tail jumps: %s\n' "$tails"
    for c in $direct $tails; do
        case " $STOP " in *" $c "*) continue ;; esac
        todo="$todo $c"
    done
done

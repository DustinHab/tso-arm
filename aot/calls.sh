#!/bin/sh
# WSL: the functions of an x86-64 binary reachable from a root through direct calls, with size and the indirect calls
# each makes. Functions are followed by address (static functions of different files may share a name) and printed
# as NAME@ADDRESS. Stops at the names listed in STOP (space separated).
#   aot/calls.sh BINARY ROOT
B=$1
ROOT=$2
nm -S -n "$B" | awk 'NF == 4 && $3 ~ /^[tTwW]$/ { print $1, $2, $4 }' >/tmp/calls-syms.txt
start=$(awk -v f="$ROOT" '$3 == f { print $1; exit }' /tmp/calls-syms.txt)
todo=$((0x$start))
seen=" "
while [ -n "$todo" ]; do
    set -- $todo
    a=$1
    shift
    todo=$*
    case "$seen" in *" $a "*) continue ;; esac
    seen="$seen$a "
    line=$(awk -v a="$(printf '%016x' $a)" '$1 == a { print; exit }' /tmp/calls-syms.txt)
    [ -z "$line" ] && { printf '%#x: no symbol\n' $a; continue; }
    f=$(echo $line | cut -d' ' -f3)
    size=$((0x$(echo $line | cut -d' ' -f2)))
    objdump -d --no-show-raw-insn --start-address=$a --stop-address=$((a + size)) "$B" | grep -E '^ +[0-9a-f]+:' >/tmp/calls-fn.s
    n=$(wc -l </tmp/calls-fn.s)
    direct=$(grep -E '\scall +[0-9a-f]+ <' /tmp/calls-fn.s | sed 's/.*call *\([0-9a-f]*\) <\(.*\)>.*/\2@\1/' | sort -u | tr '\n' ' ')
    tails=$(grep -E '\sjmp +[0-9a-f]+ <' /tmp/calls-fn.s | sed 's/.*jmp *\([0-9a-f]*\) <\(.*\)>.*/\2@\1/' | grep -v '+' | sort -u | tr '\n' ' ')
    indirect=$(grep -cE '\s(call|jmp) +\*' /tmp/calls-fn.s)
    printf '%-40s %5d bytes %5d insns  indirect %s\n    calls: %s\n' "$f@$(printf '%x' $a)" $size $n $indirect "$direct"
    [ -n "$tails" ] && printf '    tail jumps: %s\n' "$tails"
    for c in $direct $tails; do
        case " $STOP " in *" ${c%@*} "*) continue ;; esac
        case "$c" in *+*) continue ;; esac
        todo="$todo $((0x${c#*@}))"
    done
done

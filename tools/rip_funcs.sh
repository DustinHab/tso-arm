#!/bin/sh
# WSL: guest RIPs with their functions, optionally only those in the named functions.
#   tools/rip_funcs.sh BINARY "RIP RIP ..." [FUNCTION ...]
B=$1
R=$2
shift 2
for a in $R; do
    f=$(addr2line -f -e "$B" "$a" | head -n 1)
    if [ $# -eq 0 ]; then
        echo "$a $f"
    else
        for want in "$@"; do
            [ "$f" = "$want" ] && echo "$a $f"
        done
    fi
done | sort

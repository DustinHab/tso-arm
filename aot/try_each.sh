#!/bin/sh
# Test machine: each named function of a binary through the translator alone, ok or its error.
#   aot/try_each.sh BINARY FUNCTION...
cd "$(dirname "$0")/.."
b=$1
shift
for f in "$@"; do
    if python3 aot/lift.py "$b" /tmp/try-each.c "$f" >/dev/null 2>/tmp/try-each.err; then
        printf '%-28s ok\n' "$f"
    else
        printf '%-28s %s\n' "$f" "$(tail -n 1 /tmp/try-each.err | cut -c1-140)"
    fi
done

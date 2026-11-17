#!/bin/sh
# Escalated guest RIPs (unique) in a views log, optionally between two line numbers.
#   tools/esc_rips.sh LOG [FIRST LAST]
f=$1
a=${2:-1}
b=${3:-\$}
sed -n "${a},${b}p" "$f" | grep 'escalate rip' | sed 's/.*rip \(0x[0-9a-f]*\).*/\1/' | sort -u | tr '\n' ' '
echo

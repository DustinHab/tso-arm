#!/bin/sh
# Test machine: the instructions at every patched site of the last aot/try.sh run (from /tmp/aot-err.txt), with the
# function they are in, grouped by instruction form.
#   aot/patched_insns.sh WORKLOAD
cd "$(dirname "$0")/.."
w=$1
lib=out/aot/$w.so
objdump -d --no-show-raw-insn $lib >/tmp/pi-dis.txt
for off in $(grep -o 'patched [a-z]* at library+0x[0-9a-f]*' /tmp/aot-err.txt | awk '{ print $2 "," $4 }' | sed 's/library+0x//'); do
    kind=${off%%,*}
    a=${off#*,}
    printf '%-5s %6s  %s\n' $kind $a "$(grep -E "^ *$a:" /tmp/pi-dis.txt | cut -f2-)"
done

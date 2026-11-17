#!/bin/sh
# Test machine: which guest pages fault under the page protocol while the translated functions run (one logged xz
# run, TSO_VIEWS_LOG), counted per 4 KiB page and state transition.
#   aot/faults.sh
cd "$(dirname "$0")/.."
export LC_ALL=C
AOT_ENV="TSO_VIEWS_LOG=1 $AOT_ENV" sh aot/try.sh protocol >/dev/null 2>&1
grep -a -o 'fault [RW] view [0-9]* slot [0-9]* guest 0x[0-9a-f]*: [^ ]* -> [^ ]* [a-z]*' /tmp/aot-err.txt |
    awk '{ page = substr($8, 1, length($8) - 4); print $2, page "xxx", $9, $11, $12 }' | sort | uniq -c | sort -rn | head -n ${TOP:-25}
echo "accesses completed in the handler, by host pc:"
grep -a -o 'completed 0x[0-9a-f]* at pc 0x[0-9a-f]*' /tmp/aot-err.txt | awk '{ print $5 }' | sort | uniq -c | sort -rn | head -n 10

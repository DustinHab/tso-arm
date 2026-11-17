#!/bin/sh
# Which host registers the view base is added to in a dumped block (bench/dump_block.sh), most frequent first.
#   bench/view_adds.sh RIP
cd "$(dirname "$0")/.."
grep 'add.*, x24$' out/block-$1-views.s | awk '{print $3}' | sort | uniq -c | sort -rn | head -n 12

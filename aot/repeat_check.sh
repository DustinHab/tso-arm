#!/bin/sh
# Test machine: rebuilds the three translated libraries and runs each workload N times (default 4) under the page
# protocol and once without ordering, outputs checked.
#   aot/repeat_check.sh [N]
cd "$(dirname "$0")/.."
n=${1:-4}
for w in pigz xz zstd; do
    sh aot/$w.sh >/dev/null 2>&1 || { echo "$w: build failed"; sh aot/$w.sh 2>&1 | tail -n 5; exit 1; }
done
for w in pigz xz zstd; do
    sh aot/try.sh $w off 2>&1 | grep -E "^$w aot "
    for i in $(seq $n); do
        sh aot/try.sh $w protocol 2>&1 | grep -E "^$w aot "
    done
done

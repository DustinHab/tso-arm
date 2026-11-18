#!/bin/sh
# Test machine: everything before a commit that changes the mechanism: the libraries rebuilt, outputs and the
# patch stubs' general path, the views matrix, both litmus series (aot/stub_check.sh), more threads than view slots
# (tests/many_threads.sh), then the efficiency table (bench/efficiency.sh). Logs: out/full_check.log, and
# out/eff_session.log for the table.
#   tests/full_check.sh
cd "$(dirname "$0")/.."
{
    for w in pigz xz zstd; do sh aot/$w.sh >/dev/null 2>&1 || echo "$w: library build failed"; done
    sh aot/stub_check.sh 200000
    sh tools/views_matrix.sh 2>&1 | grep '^threads'
    sh tests/many_threads.sh
} >out/full_check.log 2>&1
sh bench/efficiency.sh >out/eff_session.log 2>&1

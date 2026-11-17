#!/bin/sh
# Memory events of xz -T2 under stage 1 and under the page protocol, side by side up to the first difference.
cd "$(dirname "$0")/.."
run() {
    env TSO_VIEWS=1 TSO_VIEWS_LOG=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 "$@" $HOME/opt/fex-views/bin/FEX \
        build/x86/xz -T2 -6 --block-size=2MiB -c build/corpus8.tar 2>&1 >/dev/null |
        grep '^tso-arm: \(mmap\|munmap\|mprotect\|mremap\|madvise\|detach\)' | sed 's/ slot [0-9]*$//'
}
run TSO_VIEWS_STAGE1=1 >/tmp/ev1.txt
run >/tmp/ev2.txt
wc -l /tmp/ev1.txt /tmp/ev2.txt
diff /tmp/ev1.txt /tmp/ev2.txt | head -n 40

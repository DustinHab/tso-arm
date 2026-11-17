#!/bin/sh
# xz under the page protocol with 1, 2 and 4 threads: checksum of the output and the error message, if any.
cd "$(dirname "$0")/.."
for t in 1 2 4; do
    s=$(env TSO_VIEWS=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $HOME/opt/fex-views/bin/FEX \
        build/x86/xz -T$t -6 --block-size=2MiB -c build/corpus8.tar 2>/tmp/xz$t.err | md5sum | cut -c1-8)
    n=$(FEX_TSOENABLED=0 $HOME/opt/fex/bin/FEX build/x86/xz -T$t -6 --block-size=2MiB -c build/corpus8.tar 2>/dev/null | md5sum | cut -c1-8)
    echo "T$t: protocol $s upstream $n | $(grep -v '^tso-arm' /tmp/xz$t.err | head -n 2 | tr '\n' ' ')"
    grep 'claims' /tmp/xz$t.err
done

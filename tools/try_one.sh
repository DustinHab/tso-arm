#!/bin/sh
# One workload under the page protocol with the memory event log. Log in /tmp/one.txt.
#   tools/try_one.sh zstd|pigz|xz [extra env ...]
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=$1
shift
case $w in
zstd) set -- "$@" $X/zstd -T4 -3 -f -q -c $C/corpus.tar ;;
pigz) set -- "$@" $X/pigz -n -p 4 -c $C/corpus.tar ;;
xz) set -- "$@" $X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar ;;
esac
env TSO_VIEWS=1 TSO_VIEWS_LOG=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 \
    $HOME/opt/fex-views/bin/FEX "$@" 2>/tmp/one.txt | md5sum | cut -c1-8
echo "exit status of the pipeline head is not shown; log lines: $(wc -l </tmp/one.txt)"
grep -v '^tso-arm: fault\|^tso-arm: escalate' /tmp/one.txt | tail -n 25

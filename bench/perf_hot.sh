#!/bin/sh
# Hottest translated blocks of one workload (user-mode cycles), with FEX naming its blocks for perf.
#   bench/perf_hot.sh WORKLOAD CONFIG      CONFIG: off | views (stage 1, all plain) | protocol
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=${1:-xz}
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
case ${2:-views} in
off) vars="FEX_TSOENABLED=0" bin=$HOME/opt/fex/bin/FEX ;;
views) vars="TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 FEX_TSOENABLED=0" bin=$HOME/opt/fex-views/bin/FEX ;;
protocol) vars="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" bin=$HOME/opt/fex-views/bin/FEX ;;
esac
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
env $vars $PERF_ENV FEX_BLOCKJITNAMING=1 perf record -q -e cycles:u -o /tmp/perf-hot.data $bin $cmd >/dev/null 2>/tmp/perf-hot.err
perf report -i /tmp/perf-hot.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n ${TOP:-25}

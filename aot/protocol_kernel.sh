#!/bin/sh
# Test machine: kernel time of a workload with its translated functions, without ordering and under the page protocol
# (with a profile): system calls and kernel symbols by share of the process's kernel cycles.
#   aot/protocol_kernel.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/pk-$w.prof
rm -f $prof
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib \
    $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
for cfg in off protocol; do
    case $cfg in
    off) vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    esac
    sudo env $vars HOME=$HOME perf record -q -e cycles:k -o /tmp/pk-$cfg.data $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    total=$(sudo perf report -i /tmp/pk-$cfg.data --stdio 2>/dev/null | awk '/Event count/ { print $NF }')
    echo "== $cfg: $(echo "$total / 1000000000" | bc -l | cut -c1-5) G kernel cycles"
    sudo perf report -i /tmp/pk-$cfg.data --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 12
    sudo env $vars HOME=$HOME strace -f -c -o /tmp/pk-$cfg.strace $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
    head -n 12 /tmp/pk-$cfg.strace
done

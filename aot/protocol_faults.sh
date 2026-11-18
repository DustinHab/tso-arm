#!/bin/sh
# Test machine: page faults and kernel time of a workload with its translated functions, natively, without ordering
# and under the page protocol (with a profile).
#   aot/protocol_faults.sh [WORKLOAD]
cd "$(dirname "$0")/.."
export LC_ALL=C
w=${1:-xz}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
case $w in
zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) args="-n -p 4 -c $C/corpus.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
lib=$PWD/out/aot/$w.so
prof=/tmp/pf-$w.prof
rm -f $prof
env TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib \
    $HOME/opt/fex-views/bin/FEX $X/$w $args >/dev/null 2>&1
for cfg in native off protocol; do
    case $cfg in
    native) cmd="$N/$w" vars="" ;;
    off) cmd="$HOME/opt/fex-views/bin/FEX $X/$w" vars="FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    protocol) cmd="$HOME/opt/fex-views/bin/FEX $X/$w"
        vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=$prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    esac
    env $vars /usr/bin/time -f '%e s wall, %U s user, %S s sys, %R minor faults, %F major, %c involuntary switches' $cmd $args 2>&1 >/dev/null |
        tail -n 1 | sed "s/^/$cfg: /"
done

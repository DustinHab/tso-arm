#!/bin/sh
# Test machine: dynamically linked x86-64 programs (build/x86dyn, study/build_dynamic.sh) with an x86-64 root file
# system (default build/rootfs-x86, tests/mini_rootfs.sh) under FEX's full TSO and under the page protocol, outputs
# checked against the native ones.
#   tests/dynamic_check.sh [ROOTFS]
cd "$(dirname "$0")/.."
export FEX_ROOTFS=${1:-$PWD/build/rootfs-x86}
F=$HOME/opt/fex-views/bin/FEX
C=$PWD/build
for w in pigz xz zstd; do
    case $w in
    zstd) args="-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) args="-n -p 4 -c $C/corpus.tar" ;;
    xz) args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    for cfg in full protocol; do
        case $cfg in
        full) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
        protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
        esac
        s=$(date +%s%N)
        env $vars FEX_DISABLETELEMETRY=1 timeout 300 $F build/x86dyn/$w $args >/dev/shm/dc-out 2>/tmp/dc-err
        rc=$?
        e=$(date +%s%N)
        [ "$(md5sum </dev/shm/dc-out | cut -c1-8)" = "$want" ] && ok=ok || ok=WRONG
        printf '%-5s %-9s exit %3d, %s, %5d ms | %s\n' $w $cfg $rc $ok $(( (e - s) / 1000000 )) "$(grep -v '^$' /tmp/dc-err | tail -n 1 | cut -c1-100)"
    done
done
rm -f /dev/shm/dc-out

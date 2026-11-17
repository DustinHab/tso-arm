#!/bin/sh
# IR of the block at RIP after all passes (register allocation included), as FEX compiles it without ordering and
# without view arithmetic. Output: out/ir-<rip>.txt
#   bench/dump_ir.sh WORKLOAD RIP
cd "$(dirname "$0")/.."
X=$PWD/build/x86
C=$PWD/build
w=$1
rip=$2
case $w in
zstd) cmd="$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
pigz) cmd="$X/pigz -n -p 4 -c $C/corpus.tar" ;;
xz) cmd="$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
esac
rm -rf /tmp/irdump
mkdir -p /tmp/irdump out
env TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 TSO_VIEWS_NOEXACT=1 FEX_TSOENABLED=0 \
    FEX_DUMPIR=/tmp/irdump FEX_PASSMANAGERDUMPIR=afteropt $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>/dev/null
ls /tmp/irdump | wc -l
cp /tmp/irdump/$rip-post.ir out/ir-$rip.txt 2>/dev/null || ls /tmp/irdump | grep $rip
wc -l out/ir-$rip.txt

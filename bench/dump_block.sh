#!/bin/sh
# Host code of one translated block, with views (stage 1, all plain) and without the rewriting pass, side by side
# counts and the disassembly in out/block-<rip>-{views,nopass}.s
#   bench/dump_block.sh WORKLOAD RIP      (RIP of a block entry in hex, e.g. 41b830)
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
mkdir -p out
V="TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 FEX_TSOENABLED=0 TSO_VIEWS_DUMP=$rip"
for cfg in views nopass; do
    case $cfg in
    views) vars="$V" ;;
    nopass) vars="$V TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 TSO_VIEWS_NOEXACT=1" ;;
    esac
    rm -f /tmp/tso-block-$rip.bin
    env $vars $HOME/opt/fex-views/bin/FEX $cmd >/dev/null 2>&1
    objdump -D -b binary -m aarch64 /tmp/tso-block-$rip.bin | sed -n '/<.data>:/,$p' | cut -f3- >out/block-$rip-$cfg.s
    printf '%-7s %6d instructions\n' $cfg "$(grep -c . out/block-$rip-$cfg.s)"
done
echo "most frequent instructions (views, nopass):"
for cfg in views nopass; do
    awk '{print $1}' out/block-$rip-$cfg.s | sort | uniq -c | sort -rn | head -n 12 | tr '\n' ' '
    echo
done

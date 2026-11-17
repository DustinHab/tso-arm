#!/bin/sh
# Test machine: one xz run with the translated functions, checked against the native output.
#   aot/try.sh [CONFIG]      CONFIG: off (FEX without ordering) | protocol (page protocol, default)
#   AOT_ENV="TSO_AOT_ONLY=name,..." to route only some functions
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
C=$PWD/build
case ${1:-protocol} in
off) vars="FEX_TSOENABLED=0" ;;
protocol) vars="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1" ;;
esac
want=$(grep "^xz " build/expected.md5 | cut -d' ' -f2)
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
s=$(date +%s.%N)
env $vars TSO_AOT=$PWD/out/aot/xz.so TSO_AOT_LOG=1 $AOT_ENV $HOME/opt/fex-views/bin/FEX $X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar \
    >/dev/shm/aot-out 2>/tmp/aot-err.txt
r=$?
e=$(date +%s.%N)
sum=$(md5sum </dev/shm/aot-out | cut -c1-8)
rm -f /dev/shm/aot-out
ok=ok
[ "$sum" != "$want" ] && ok="WRONG ($sum, want $want)"
[ "$r" != 0 ] && ok="exit $r"
printf 'xz aot %s: %.2f s, %s\n' "${1:-protocol}" "$(echo "$e - $s" | bc)" "$ok"
head -n 30 /tmp/aot-err.txt

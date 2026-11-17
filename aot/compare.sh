#!/bin/sh
# Test machine: xz natively, under FEX and under FEX with the functions translated ahead of time; median of N runs
# (default 5) at a fixed 1.8 GHz after cooling below 65 °C, output checked each time.
#   aot/compare.sh [N]      CONFIGS="native off off-aot protocol protocol-aot" to choose
cd "$(dirname "$0")/.."
export LC_ALL=C
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
n=${1:-5}
args="-T4 -6 --block-size=2MiB -c $C/corpus8.tar"
want=$(grep "^xz " build/expected.md5 | cut -d' ' -f2)
P="TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1"
trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/aot-out' EXIT
sh tools/freq.sh fix 1800000 >/dev/null
native=
for cfg in ${CONFIGS:-native off off-aot protocol protocol-aot}; do
    case $cfg in
    native) cmd="$N/xz" vars="" ;;
    off) cmd="$HOME/opt/fex-views/bin/FEX $X/xz" vars="FEX_TSOENABLED=0" ;;
    off-aot) cmd="$HOME/opt/fex-views/bin/FEX $X/xz" vars="FEX_TSOENABLED=0 TSO_AOT=$PWD/out/aot/xz.so" ;;
    protocol) cmd="$HOME/opt/fex-views/bin/FEX $X/xz" vars="$P" ;;
    protocol-aot) cmd="$HOME/opt/fex-views/bin/FEX $X/xz" vars="$P TSO_AOT=$PWD/out/aot/xz.so" ;;
    # with the profile of a previous run of the same configuration (one run first, not counted)
    protocol-warm | protocol-aot-warm)
        cmd="$HOME/opt/fex-views/bin/FEX $X/xz"
        vars="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1"
        [ $cfg = protocol-aot-warm ] && vars="$vars TSO_AOT=$PWD/out/aot/xz.so"
        rm -f $HOME/.cache/tso-arm/xz-*.prof
        env $vars $cmd $args >/dev/null 2>&1
        ;;
    esac
    times=""
    ok=ok
    for i in $(seq $n); do
        while [ "$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)" -ge 65 ]; do sleep 5; done
        s=$(date +%s.%N)
        env $vars $AOT_ENV $cmd $args >/dev/shm/aot-out 2>/dev/null || ok="exit $?"
        e=$(date +%s.%N)
        [ "$(md5sum </dev/shm/aot-out | cut -c1-8)" != "$want" ] && ok=WRONG
        times="$times $(echo "$e - $s" | bc)"
    done
    med=$(echo $times | tr ' ' '\n' | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
    [ $cfg = native ] && native=$med
    eff=""
    [ -n "$native" ] && eff=$(echo "$native $med" | awk '{ printf "%5.1f %%", 100 * $1 / $2 }')
    printf '%-13s %7.3f s  %s  %s   (%s)\n' $cfg $med "$eff" $ok "$(echo $times)"
done

#!/bin/sh
# Runs the static x86-64 workloads under FEX with different ordering settings on the test machine.
#   bench/run_fex.sh [workload ...]      (ROUNDS=3, KHZ=1800000)
# Raw lines: out/fex_runs.txt (workload config round wall user sys md5), summary: out/fex_summary.txt
cd "$(dirname "$0")/.."
FEX=$HOME/opt/fex/bin/FEX
FEXO=$HOME/opt/fex-oracle/bin/FEX
X=$PWD/build/x86
C=$PWD/build
L=$PWD/build/lists
ROUNDS=${ROUNDS:-3}
raw=out/fex_runs.txt
mkdir -p out
WORKLOADS=${*:-zstd pigz xz 7zz}

cmd_of() {
    case $1 in
    zstd) echo "$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "$X/pigz -n -p 4 -c $C/corpus.tar" ;;
    xz) echo "$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    7zz) echo "$X/7zz b 1 -mmt4 -md20" ;;
    esac
}

# config name -> environment and translator
run_config() {
    w=$1 cfg=$2 r=$3
    cmd=$(cmd_of $w)
    case $cfg in
    off) set -- FEX_TSOENABLED=0 $FEX ;;
    default) set -- FEX_DUMMY=1 $FEX ;;
    full) set -- FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEX ;;
    oracle-full) set -- FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 TSO_PLAIN_LIST=$L/$w.plain $FEXO ;;
    oracle-default) set -- TSO_PLAIN_LIST=$L/$w.plain $FEXO ;;
    esac
    /usr/bin/time -f '%e %U %S' -o /dev/shm/tso-time env "$@" $cmd >/dev/shm/tso-out 2>/dev/null
    sum=$(md5sum </dev/shm/tso-out | cut -c1-8)
    [ $w = 7zz ] && sum=-
    echo "$w $cfg $r $(cat /dev/shm/tso-time | tail -n 1) $sum" | tee -a $raw
}

trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/tso-out /dev/shm/tso-time' EXIT
sh tools/freq.sh fix ${KHZ:-1800000} >/dev/null
for w in $WORKLOADS; do
    for r in $(seq 1 $ROUNDS); do
        for cfg in off default full oracle-full oracle-default; do
            run_config $w $cfg $r
        done
    done
done
vcgencmd get_throttled

# summary: fastest wall time per workload and config, relative to 'off'
LC_ALL=C awk '{ k = $1 " " $2; if (!(k in best) || $4 < best[k]) { best[k] = $4; usr[k] = $5 } ; w[$1] = 1; md5[k] = $7 }
     END {
       n = split("off default full oracle-full oracle-default", cf, " ");
       printf "%-6s", "";
       for (i = 1; i <= n; i++) printf " %16s", cf[i];
       printf "\n";
       for (x in w) {
         printf "%-6s", x;
         for (i = 1; i <= n; i++) { k = x " " cf[i]; printf " %7.2fs (%5.2f)", best[k], best[k] / best[x " off"] }
         printf "\n";
       }
     }' $raw | tee out/fex_summary.txt

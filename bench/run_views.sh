#!/bin/sh
# The workloads under FEX with and without views. Configurations:
#   off, default, full        upstream FEX: no ordering / its defaults (vectors and memcpy unordered) / everything ordered
#   views-off, views-full     stage 1: all accesses through the views, all plain / all ordered
#   protocol                  stage 2: page protocol, plain accesses to thread-private pages, everything else ordered
# Raw lines: out/views_runs.txt (workload config round wall user sys md5 ok), summary out/views_summary.txt
#   bench/run_views.sh [workload ...]      (ROUNDS=3, KHZ=1800000, CONFIGS="off default full protocol")
cd "$(dirname "$0")/.."
FEX=$HOME/opt/fex/bin/FEX
FEXV=$HOME/opt/fex-views/bin/FEX
X=$PWD/build/x86
C=$PWD/build
ROUNDS=${ROUNDS:-3}
raw=out/views_runs.txt
mkdir -p out
WORKLOADS=${*:-zstd pigz xz}
CONFIGS=${CONFIGS:-off default full protocol}

cmd_of() {
    case $1 in
    zstd) echo "$X/zstd -T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "$X/pigz -n -p 4 -c $C/corpus.tar" ;;
    xz) echo "$X/xz -T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    7zz) echo "$X/7zz b 1 -mmt4 -md20" ;;
    esac
}

run_config() {
    w=$1 cfg=$2 r=$3
    case $cfg in
    off) set -- FEX_TSOENABLED=0 $FEX ;;
    default) set -- $FEX ;;
    full) set -- FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEX ;;
    views-off) set -- TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 FEX_TSOENABLED=0 $FEXV ;;
    views-full) set -- TSO_VIEWS=1 TSO_VIEWS_STAGE1=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    protocol) set -- TSO_VIEWS=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    # escalation of the whole block instead of the single instruction
    protocol-block) set -- TSO_VIEWS=1 TSO_VIEWS_ESC=block TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    # first run without a profile; the same with migratory ownership (TSO_VIEWS_MIGRATE=1); without the fallback
    protocol-cold) set -- TSO_VIEWS=1 TSO_VIEWS_PROFILE=none TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    protocol-mig) set -- TSO_VIEWS=1 TSO_VIEWS_PROFILE=none TSO_VIEWS_MIGRATE=1 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    protocol-nofb) set -- TSO_VIEWS=1 TSO_VIEWS_PROFILE=none TSO_VIEWS_BUDGET=0 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    # pages change state one at a time, no chunks
    protocol-nochunk) set -- TSO_VIEWS=1 TSO_VIEWS_CHUNK=0 TSO_VIEWS_STATS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV ;;
    # cost breakdown: identity base (arithmetic, no view), and additionally no rewriting pass (shared memory only)
    views-id) set -- TSO_VIEWS=1 TSO_VIEWS_IDENTITY=1 FEX_TSOENABLED=0 $FEXV ;;
    views-id-nopass) set -- TSO_VIEWS=1 TSO_VIEWS_IDENTITY=1 TSO_VIEWS_NOPASS=1 FEX_TSOENABLED=0 $FEXV ;;
    esac
    timeout 600 /usr/bin/time -f '%e %U %S' -o /dev/shm/tso-time env "$@" $(cmd_of $w) >/dev/shm/tso-out 2>/dev/shm/tso-err
    rc=$?
    sum=$(md5sum </dev/shm/tso-out | cut -c1-8)
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    ok=ok
    [ -n "$want" ] && [ "$sum" != "$want" ] && ok=WRONG
    [ $rc -ne 0 ] && ok="exit$rc"
    [ $w = 7zz ] && sum=-
    echo "$w $cfg $r $(tail -n 1 /dev/shm/tso-time) $sum $ok" | tee -a $raw
    [ "$ok" != ok ] && tail -n 5 /dev/shm/tso-err
    grep -E '^tso-arm: (claims|handled)' /dev/shm/tso-err | sed "s/^tso-arm:/$w $cfg $r:/" | tee -a out/views_stats.txt
}

trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/tso-out /dev/shm/tso-time /dev/shm/tso-err' EXIT
sh tools/freq.sh fix ${KHZ:-1800000} >/dev/null
for w in $WORKLOADS; do
    for r in $(seq 1 $ROUNDS); do
        for cfg in $CONFIGS; do
            run_config $w $cfg $r
        done
    done
done
vcgencmd get_throttled

LC_ALL=C awk -v cfgs="$CONFIGS" '$8 == "ok" { k = $1 " " $2; if (!(k in best) || $4 < best[k]) best[k] = $4; w[$1] = 1 }
     END {
       n = split(cfgs, cf, " ");
       printf "%-6s", ""; for (i = 1; i <= n; i++) printf " %16s", cf[i]; printf "\n";
       for (x in w) {
         printf "%-6s", x;
         for (i = 1; i <= n; i++) { k = x " " cf[i]; if (k in best) printf " %7.2fs (%5.2f)", best[k], best[k] / best[x " off"]; else printf " %16s", "-" }
         printf "\n";
       }
     }' $raw | tee out/views_summary.txt

#!/bin/sh
# Efficiency of x86-64 emulation against native AArch64 builds of the same programs.
#   efficiency = native wall time / wall time of the x86-64 build under the configuration
# Same inputs, same thread count, fixed clock. Every output is checked against the x86-64 reference checksum.
# Raw lines: out/efficiency_runs.txt; table for the README: out/efficiency.md
#   bench/efficiency.sh [workload ...]      (ROUNDS=3, KHZ=1800000, CONFIGS="native off default full protocol")
cd "$(dirname "$0")/.."
FEX=$HOME/opt/fex/bin/FEX
FEXV=$HOME/opt/fex-views/bin/FEX
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
ROUNDS=${ROUNDS:-3}
KHZ=${KHZ:-1800000}
raw=out/efficiency_runs.txt
mkdir -p out
WORKLOADS=${*:-zstd pigz xz}
CONFIGS=${CONFIGS:-native off default full protocol}
stamp=$(date +%Y-%m-%dT%H:%M)

args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $C/corpus.tar" ;;
    pigz) echo "-n -p 4 -c $C/corpus.tar" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    esac
}

run_config() {
    w=$1 cfg=$2 r=$3
    case $cfg in
    native) set -- $N/$w ;;
    off) set -- env FEX_TSOENABLED=0 $FEX $X/$w ;;
    default) set -- $FEX $X/$w ;;
    full) set -- env FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEX $X/$w ;;
    protocol) set -- env TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV $X/$w ;;
    esac
    timeout 600 /usr/bin/time -f '%e %U %S' -o /dev/shm/eff-time "$@" $(args_of $w) >/dev/shm/eff-out 2>/dev/shm/eff-err
    rc=$?
    sum=$(md5sum </dev/shm/eff-out | cut -c1-8)
    want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    ok=ok
    [ -n "$want" ] && [ "$sum" != "$want" ] && ok=WRONG
    [ $rc -ne 0 ] && ok="exit$rc"
    echo "$stamp $w $cfg $r $(tail -n 1 /dev/shm/eff-time) $sum $ok" | tee -a $raw
}

trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/eff-out /dev/shm/eff-time /dev/shm/eff-err' EXIT
sh tools/freq.sh fix $KHZ >/dev/null
for r in $(seq 1 $ROUNDS); do
    for w in $WORKLOADS; do
        for cfg in $CONFIGS; do
            run_config $w $cfg $r
        done
    done
done
throttled=$(vcgencmd get_throttled | cut -d= -f2)

# Table from this session's runs: best wall time per workload and configuration
LC_ALL=C awk -v s="$stamp" -v cfgs="$CONFIGS" -v khz="$KHZ" -v thr="$throttled" '
  $1 == s && $9 == "ok" { k = $2 " " $3; if (!(k in best) || $5 < best[k]) best[k] = $5; w[$2] = 1 }
  $1 == s && $9 != "ok" { bad[$2 " " $3] = $9 }
  END {
    n = split(cfgs, cf, " ");
    label["native"] = "native Arm"; label["off"] = "FEX, TSO off";
    label["default"] = "FEX default"; label["full"] = "FEX full TSO"; label["protocol"] = "tso-arm protocol";
    tso["native"] = "-"; tso["off"] = "no"; tso["default"] = "no"; tso["full"] = "yes"; tso["protocol"] = "yes";
    printf "Measured %s, Raspberry Pi 5 at %.1f GHz, 4 threads, best of the rounds, wall time.\n\n", s, khz / 1e6;
    printf "| Configuration | x86 memory order kept |";
    m = 0; for (x in w) names[++m] = x;
    for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (names[j] < names[i]) { t = names[i]; names[i] = names[j]; names[j] = t }
    for (i = 1; i <= m; i++) printf " %s |", names[i];
    printf " geometric mean |\n|---|---|";
    for (i = 1; i <= m; i++) printf "---|"; printf "---|\n";
    for (c = 1; c <= n; c++) {
      printf "| %s | %s |", label[cf[c]], tso[cf[c]];
      lg = 0; cnt = 0;
      for (i = 1; i <= m; i++) {
        k = names[i] " " cf[c]; nk = names[i] " native";
        if ((k in best) && (nk in best)) {
          e = best[nk] / best[k]; lg += log(e); cnt++;
          printf " %.2f s, %.0f %% |", best[k], 100 * e;
        } else if (k in bad) printf " %s |", bad[k];
        else printf " - |";
      }
      if (cnt == m) printf " %.0f %% |\n", 100 * exp(lg / cnt); else printf " - |\n";
    }
    printf "\nEfficiency = native time / time; 100 %% is native speed. Throttling flags after the run: %s.\n", thr;
  }' $raw | tee out/efficiency.md

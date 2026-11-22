#!/bin/sh
# Efficiency of x86-64 emulation against native AArch64 builds of the same programs.
#   efficiency = native wall time / wall time of the x86-64 build under the configuration
# Same inputs, same thread count, fixed clock. Every output is checked against the x86-64 reference checksum.
# Raw lines: out/efficiency_runs.txt; table for the README: out/efficiency.md
#   bench/efficiency.sh [workload ...]      (ROUNDS=5, KHZ=1800000,
#       CONFIGS="native off ours-off default full protocol-cold protocol aot-off aot-full aot")
# The aot configurations need the workload's library of functions translated ahead of time (out/aot/WORKLOAD.so,
# from aot/WORKLOAD.sh); without it they are left out.
# FEXV: the tso-arm FEX to measure (default the development build; the installed one is ~/.local/opt/tso-arm/bin/FEX)
cd "$(dirname "$0")/.."
FEX=$HOME/opt/fex/bin/FEX
FEXV=${FEXV:-$HOME/opt/fex-views/bin/FEX}
X=$PWD/build/x86
N=$PWD/build/arm64
C=$PWD/build
# Five rounds: under FEX, pigz's wall time falls into two groups about 40 ms apart from run to run (notes section
# 22), and the profile configurations learn in the first round
ROUNDS=${ROUNDS:-5}
KHZ=${KHZ:-1800000}
raw=out/efficiency_runs.txt
mkdir -p out
WORKLOADS=${*:-zstd pigz xz}
CONFIGS=${CONFIGS:-native off ours-off default full protocol-cold protocol aot-off aot-full aot}
FEXENV=${FEXENV-FEX_DISABLETELEMETRY=1}
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
    # the tso-arm build without views and without ordering: its code generation changes alone
    ours-off) set -- env FEX_TSOENABLED=0 $FEXV $X/$w ;;
    default) set -- $FEX $X/$w ;;
    full) set -- env FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEX $X/$w ;;
    # tso-arm's configurations compile FEX's multiblock units of at most 150 instructions, as bin/tso-arm does
    # (FEX's own: 5000; notes section 43)
    # with the profile of earlier runs (the first round writes it)
    protocol) set -- env FEX_MAXINST=150 TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV $X/$w ;;
    # without any profile: everything learned in this run
    protocol-cold) set -- env FEX_MAXINST=150 TSO_VIEWS=1 TSO_VIEWS_PROFILE=none FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 $FEXV $X/$w ;;
    # the hot functions translated ahead of time (aot/), the rest by FEX: without ordering, and with the page
    # protocol and a profile of its own
    # FEX compiles the rest block by block (FEX_MULTIBLOCK=0): with the hot code translated ahead of time, compiling
    # whole functions costs more at start-up than it gains (notes section 18)
    aot-off | aot-full | aot)
        lib=$PWD/out/aot/$w.so
        [ -f $lib ] || return
        if [ $cfg = aot-off ]; then
            set -- env FEX_MAXINST=150 FEX_TSOENABLED=0 FEX_MULTIBLOCK=0 TSO_AOT=$lib $FEXV $X/$w
        elif [ $cfg = aot-full ]; then
            # no page protocol: FEX full TSO, the translated functions ordered throughout
            set -- env FEX_MAXINST=150 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 TSO_AOT=$lib $FEXV $X/$w
        else
            set -- env FEX_MAXINST=150 TSO_VIEWS=1 TSO_VIEWS_PROFILE=$HOME/.cache/tso-arm/$w-aot.prof FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 \
                FEX_MULTIBLOCK=0 TSO_AOT=$lib $FEXV $X/$w
        fi
        ;;
    esac
    # FEXENV: settings for every FEX configuration (FEX reads its options from the environment). By default FEX's
    # telemetry is off in all of them: FEX writes its telemetry file at every exit with an fsync, 7 ms per process on
    # the test machine's SD card (bench/startup_aot.sh), which has nothing to do with translation
    [ $cfg != native ] && [ -n "$FEXENV" ] && set -- env $FEXENV "$@"
    # every run starts cool, the native ones included (a warm chip made native xz 5 % slower in one session)
    cooldown
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
# Profiles start empty for every measurement
rm -f $HOME/.cache/tso-arm/*.prof
sh tools/freq.sh fix $KHZ >/dev/null
# The test machine has no fan: start every run below COOL degrees (at most two minutes of waiting)
cooldown() {
    i=0
    while [ $i -lt 24 ]; do
        t=$(vcgencmd measure_temp | sed 's/[^0-9.]//g' | cut -d. -f1)
        [ "$t" -lt ${COOL:-60} ] && return
        sleep 5
        i=$((i + 1))
    done
}
# The aot configuration as `tso-arm learn` leaves a program: one that falls back to full ordering migrates where that
# is faster here (aot/stage.py times both and writes its profile; notes section 55)
case " $CONFIGS " in
*" aot "*)
    for w in $WORKLOADS; do
        [ -f $PWD/out/aot/$w.so ] || continue
        cooldown
        TSO_ARM_FEX=$FEXV python3 aot/stage.py $X/$w --profile $HOME/.cache/tso-arm/$w-aot.prof --env FEX_MAXINST=150 \
            --env FEX_MULTIBLOCK=0 --env TSO_AOT=$PWD/out/aot/$w.so $(for e in $FEXENV; do printf -- '--env %s ' "$e"; done) \
            -- $(args_of $w) | sed "s/^/$w /"
    done
    ;;
esac
for r in $(seq 1 $ROUNDS); do
    cooldown
    for w in $WORKLOADS; do
        for cfg in $CONFIGS; do
            run_config $w $cfg $r
        done
    done
done
throttled=$(vcgencmd get_throttled | cut -d= -f2)

# Table from this session's runs: best wall time per workload and configuration
LC_ALL=C awk -v s="$stamp" -v cfgs="$CONFIGS" -v khz="$KHZ" -v thr="$throttled" -v fexenv="$FEXENV" '
  $1 == s && $9 == "ok" { k = $2 " " $3; if (!(k in best) || $5 < best[k]) best[k] = $5; w[$2] = 1 }
  $1 == s && $9 != "ok" { bad[$2 " " $3] = $9 }
  END {
    n = split(cfgs, cf, " ");
    label["native"] = "native Arm"; label["off"] = "FEX, TSO off"; label["ours-off"] = "tso-arm build, TSO off";
    label["default"] = "FEX default"; label["full"] = "FEX full TSO";
    label["protocol-cold"] = "tso-arm, first run"; label["protocol"] = "tso-arm, with profile";
    label["aot-off"] = "ahead of time, TSO off"; label["aot-full"] = "ahead of time, all ordered";
    label["aot"] = "ahead of time + tso-arm, with profile";
    tso["native"] = "-"; tso["off"] = "no"; tso["ours-off"] = "no"; tso["default"] = "no"; tso["full"] = "yes, except stack accesses through RSP"; tso["protocol-cold"] = "yes"; tso["protocol"] = "yes";
    tso["aot-off"] = "no"; tso["aot-full"] = "yes, except stack accesses through RSP"; tso["aot"] = "yes";
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
    if (fexenv != "") printf "Every FEX configuration ran with %s.\n", fexenv;
  }' $raw | tee out/efficiency.md

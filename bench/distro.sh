#!/bin/sh
# Programs as a distribution ships them: the x86-64 builds of Ubuntu 24.04 (the root file system `tso-arm rootfs`
# fetches), dynamically linked, most of their work in shared libraries: xz (liblzma), gzip, bzip2 (libbz2) and
# openssl's sha512 (libcrypto). Against the host's own Arm builds of the same programs (the host distribution's
# versions). Each program learned first with `tso-arm learn` (in a cache of this script's own), then best of ROUNDS:
# native Arm, FEX's full TSO, tso-arm with the page protocol alone (--no-aot), and tso-arm with what learn translated.
# Every output is checked: the compressors' by decompressing it with the host's tools (the formats are the same, the
# bytes may differ between versions), the digest against the host's.
#   bench/distro.sh            ROUNDS (default 3), KHZ (default 1800000); table: out/distro.md, raw lines
#                              out/distro_runs.txt
#   bench/distro.sh --table STAMP    the table again from the raw lines of an earlier session
cd "$(dirname "$0")/.."
if [ "${1:-}" = --table ]; then
    stamp=$2
    raw=out/distro_runs.txt
    PROGRAMS="xz gzip bzip2 openssl"
    KHZ=${KHZ:-1800000}
    throttled=${THROTTLED:-"(not recorded)"}
else
ROUNDS=${ROUNDS:-3}
KHZ=${KHZ:-1800000}
T=$PWD/bin/tso-arm
C=$PWD/build
R=${ROOTFS:-$(ls -d "$HOME"/.local/share/fex-emu/RootFS/*/ 2>/dev/null | head -n 1)}
R=${R%/}
[ -x "$R/usr/bin/xz" ] || {
    echo "no x86-64 root file system with xz: 'tso-arm rootfs' fetches one (or set ROOTFS)"
    exit 2
}
mkdir -p out
raw=out/distro_runs.txt
stamp=$(date +%Y-%m-%dT%H:%M)
export XDG_CACHE_HOME=$PWD/out/distro-cache
rm -rf "$XDG_CACHE_HOME"
PROGRAMS="xz gzip bzip2 openssl"

args_of() {
    case $1 in
    xz) echo "-T4 -6 --block-size=2MiB -c $C/corpus8.tar" ;;
    gzip) echo "-6 -c $C/corpus.tar" ;;
    bzip2) echo "-9 -c $C/corpus8.tar" ;;
    openssl) echo "dgst -sha512 $C/corpus.tar" ;;
    esac
}
# the output's check: the input again for the compressors, the digest line for openssl
check_of() {
    case $1 in
    xz) xz -dc | md5sum | cut -c1-8 ;;
    gzip) gzip -dc | md5sum | cut -c1-8 ;;
    bzip2) bzip2 -dc | md5sum | cut -c1-8 ;;
    openssl) sed 's/.*= //' | md5sum | cut -c1-8 ;;
    esac
}
cooldown() {
    i=0
    while [ $i -lt 24 ]; do
        t=$(vcgencmd measure_temp 2>/dev/null | sed 's/[^0-9.]//g' | cut -d. -f1)
        [ -z "$t" ] || [ "$t" -lt ${COOL:-60} ] && return
        sleep 5
        i=$((i + 1))
    done
}
run_config() {
    p=$1 cfg=$2 r=$3
    # each configuration with a page protocol profile of its own, from its own earlier rounds: a profile only grows
    # (the code ranges that met shared memory), and the later configuration would inherit the earlier one's
    case $cfg in
    native) set -- "$p" ;;
    # FEX's full TSO with FEX's own settings (tso-arm compiles smaller units, bin/tso-arm)
    full) set -- env FEX_MAXINST=5000 "$T" run --mode full "$R/usr/bin/$p" ;;
    protocol) set -- env TSO_VIEWS_PROFILE="$XDG_CACHE_HOME/$p-protocol.prof" "$T" run --no-aot "$R/usr/bin/$p" ;;
    learned) set -- env TSO_VIEWS_PROFILE="$XDG_CACHE_HOME/$p-learned.prof" "$T" run "$R/usr/bin/$p" ;;
    esac
    cooldown
    timeout 900 /usr/bin/time -f '%e' -o /dev/shm/distro-time "$@" $(args_of $p) >/dev/shm/distro-out 2>/dev/shm/distro-err
    rc=$?
    sum=$(check_of $p </dev/shm/distro-out)
    ok=ok
    [ "$sum" != "$(eval echo \$want_$p)" ] && ok=WRONG
    [ $rc -ne 0 ] && ok="exit$rc"
    echo "$stamp $p $cfg $r $(tail -n 1 /dev/shm/distro-time) $sum $ok" | tee -a $raw
}

trap 'sh tools/freq.sh restore >/dev/null; rm -f /dev/shm/distro-out /dev/shm/distro-time /dev/shm/distro-err' EXIT
want_xz=$(md5sum <$C/corpus8.tar | cut -c1-8)
want_gzip=$(md5sum <$C/corpus.tar | cut -c1-8)
want_bzip2=$want_xz
want_openssl=$(openssl dgst -sha512 $C/corpus.tar | sed 's/.*= //' | md5sum | cut -c1-8)
mkdir -p "$XDG_CACHE_HOME"
# learn at the same fixed clock and from a cool start: its timed runs decide whether the translations stay
sh tools/freq.sh fix $KHZ >/dev/null
for p in $PROGRAMS; do
    echo "== learn $p"
    cooldown
    $T learn "$R/usr/bin/$p" $(args_of $p) 2>&1 | grep -E '^(  hot|  stays|chosen|timed|learned|tso-arm)'
done
for r in $(seq 1 $ROUNDS); do
    for p in $PROGRAMS; do
        for cfg in native full protocol learned; do
            run_config $p $cfg $r
        done
    done
done
throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
fi

LC_ALL=C awk -v s="$stamp" -v khz="$KHZ" -v thr="$throttled" -v progs="$PROGRAMS" '
  $1 == s && $7 == "ok" { k = $2 " " $3; if (!(k in best) || $5 < best[k]) best[k] = $5 }
  $1 == s && $7 != "ok" { bad[$2 " " $3] = $7 }
  function cell(p, c,   k) {
    k = p " " c
    if (k in bad) return bad[k]
    if (!(k in best)) return "-"
    return sprintf("%.2f s, %d %%", best[k], best[p " native"] / best[k] * 100 + 0.5)
  }
  END {
    printf "Measured %s, Raspberry Pi 5 at %.1f GHz, best of the rounds, wall time; the Ubuntu 24.04 x86-64 builds against the host'"'"'s Arm builds.\n\n", s, khz / 1e6
    print "| Program (its library) | native Arm | FEX full TSO | tso-arm, page protocol | tso-arm, learned |"
    print "|---|---|---|---|---|"
    n = split(progs, P, " ")
    lib["xz"] = "liblzma"; lib["gzip"] = "-"; lib["bzip2"] = "libbz2"; lib["openssl"] = "libcrypto, sha512"
    for (i = 1; i <= n; i++) {
      p = P[i]
      printf "| %s (%s) | %s | %s | %s | %s |\n", p, lib[p], cell(p, "native"), cell(p, "full"), cell(p, "protocol"), cell(p, "learned")
    }
    split("native full protocol learned", Cf, " ")
    printf "| geometric mean |"
    for (j = 1; j <= 4; j++) {
      g = 0; m = 0
      for (i = 1; i <= n; i++) {
        k = P[i] " " Cf[j]
        if (k in best && (P[i] " native") in best) { g += log(best[P[i] " native"] / best[k]); m++ }
      }
      printf " %s |", m == n ? sprintf("%d %%", exp(g / n) * 100 + 0.5) : "-"
    }
    printf "\n"
    printf "\nEfficiency = native time / time. Throttling flags after the run: %s. Every output checked.\n", thr
  }' $raw >out/distro.md
cat out/distro.md

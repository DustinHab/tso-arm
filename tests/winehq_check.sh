#!/bin/sh
# Windows programs the way a user runs them: 'tso-arm wine' (WineHQ's build for Ubuntu 24.04, fetched on first use)
# with the root file system 'tso-arm rootfs' fetched, a Wine prefix of its own, then a Windows program in each
# ordering mode. The program is tests/win/spsc.c built with MinGW: a ring buffer between two Win32 threads that relies
# on x86's order.
#   tests/winehq_check.sh SPSC.EXE     MESSAGES (default 20000000), MODES (default: tso full unordered)
# Exit status 1 if it fails with x86 order kept or under full TSO.
cd "$(dirname "$0")/.."
T=${TSO_ARM:-$PWD/bin/tso-arm} # TSO_ARM: an installed tso-arm instead of this checkout's
exe=$(readlink -f "${1:?usage: tests/winehq_check.sh SPSC.EXE}")
n=${MESSAGES:-20000000}
export WINEPREFIX=${WINEPREFIX:-$HOME/.wine-tso-arm-check}
# FEX's server keeps the root file system of the program that started it until a second after its last one: one a
# program with another root file system started (FEX_ROOTFS) would serve Wine that one ("/lib/ld-linux.so.2: could
# not open")
for i in $(seq 100); do
    pgrep -u "$(id -u)" -x FEXServer >/dev/null 2>&1 || break
    sleep 0.2
done
pgrep -u "$(id -u)" -x FEXServer >/dev/null 2>&1 && { echo "FAIL: a FEXServer of another program still runs"; exit 1; }
$T wine install >/dev/null || { echo "FAIL: tso-arm wine install"; exit 1; }
echo "      $($T wine)"
w=$($T wine | sed -n 's/^Wine .* in \(.*\)$/\1/p')/opt/wine-stable/bin/wineserver
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    s=$(date +%s)
    TSO_ARM_MODE=full timeout 1200 $T wine wineboot --init >/tmp/wineboot-$$.log 2>&1
    TSO_ARM_MODE=full timeout 120 $T run $w -w
    [ -f "$WINEPREFIX/system.reg" ] || { echo "FAIL: wineboot made no prefix:"; tail -n 15 /tmp/wineboot-$$.log; exit 1; }
    echo "ok:   a Wine prefix made in $(($(date +%s) - s)) s"
fi
fail=0
for m in ${MODES:-tso full unordered}; do
    s=$(date +%s%N)
    st=0
    # into a file, not a pipe: Wine's processes left behind (under the page protocol) would hold a pipe open
    log=/tmp/winehq-$$-$m.log
    TSO_ARM_MODE=$m WINEDEBUG=err+all timeout 900 $T wine "$exe" $n >$log 2>&1 </dev/null || st=$?
    ms=$((($(date +%s%N) - s) / 1000000))
    all=$(tr -d '\r' <$log) # a Windows program's lines end in CR LF
    rm -f $log
    out=$(printf '%s\n' "$all" | grep '^spsc:' | tail -n 1)
    sleep 3
    left=$(pgrep -u "$(id -u)" -c -f '\.exe' || true)
    [ "${left:-0}" -gt 0 ] && echo "      $m: $left Windows processes still there 3 s after the program (wineserver -k ends them)"
    TSO_ARM_MODE=full timeout 120 $T run $w -k >/dev/null 2>&1
    if [ $m = unordered ]; then
        echo "      without ordering, for comparison: ${out:-exit status $st} ($ms ms)"
    elif [ "$out" = "spsc: $n messages, 0 arrived wrong" ]; then
        echo "ok:   $m: $out ($ms ms)"
    else
        echo "FAIL: $m: exit status $st: $(printf '%s\n' "$all" | grep -v '^preloader' | tail -n 3 | tr '\n' ' ')"
        fail=1
    fi
done
exit $fail

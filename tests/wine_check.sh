#!/bin/sh
# Windows programs through Wine under tso-arm: Wine from tools/wine_rootfs.sh (Ubuntu's wine64 and its libraries),
# a Wine prefix made once (wineboot), then the programs of tests/win with x86 order kept, under FEX's full TSO and
# without ordering. spsc.exe is a ring buffer between two Win32 threads that relies on x86's order.
#   tests/wine_check.sh WINE-ROOTFS.tar.zst|DIR     MESSAGES (default 20000000)
# Exit status 1 if a program fails with x86 order kept or under full TSO.
set -e
cd "$(dirname "$0")/.."
R=$PWD
T=$R/bin/tso-arm
[ $# = 1 ] || { echo "usage: tests/wine_check.sh WINE-ROOTFS.tar.zst|DIR" >&2; exit 1; }
if [ -d "$1" ]; then
    root=$(readlink -f "$1")
else
    root=$R/build/wine-rootfs
    stamp="$(stat -c %s-%Y "$1")"
    if [ "$(cat $root.stamp 2>/dev/null)" != "$stamp" ]; then
        rm -rf $root && mkdir -p $root
        zstd -dc "$1" | tar -C $root -xf -
        echo "$stamp" >$root.stamp
    fi
fi
n=${MESSAGES:-20000000}
wine=$root/usr/lib/wine/wine64
server=$root/usr/lib/wine/wineserver64
[ -x "$server" ] || server=$root/usr/lib/wine/wineserver
export FEX_ROOTFS=$root WINEPREFIX=$R/build/wineprefix WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
# FEX's server keeps the root file system of the program that started it until a second after its last one
for i in $(seq 50); do
    pgrep -u "$(id -u)" -x FEXServer >/dev/null 2>&1 || break
    sleep 0.2
done
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    s=$(date +%s)
    timeout 1200 $T run $wine wineboot --init >$R/build/wineboot.log 2>&1 || true
    timeout 120 $T run $server -w || true
    [ -f "$WINEPREFIX/system.reg" ] || {
        echo "FAIL: wineboot made no prefix:"
        tail -n 20 $R/build/wineboot.log
        exit 1
    }
    echo "ok:   a Wine prefix made in $(($(date +%s) - s)) s"
fi
fail=0
for m in tso full unordered; do
    s=$(date +%s%N)
    st=0
    out=$(timeout 900 $T run --mode $m $wine $root/opt/tso-arm-tests/spsc.exe $n 2>&1 | tail -n 1) || st=$?
    ms=$((($(date +%s%N) - s) / 1000000))
    timeout 120 $T run $server -k >/dev/null 2>&1 || true
    case $m:$st in
    unordered:*) echo "      without ordering, for comparison: $out ($ms ms)" ;;
    *:0) echo "ok:   $m: $out ($ms ms)" ;;
    *) echo "FAIL: $m: exit status $st: $out" && fail=1 ;;
    esac
done
exit $fail

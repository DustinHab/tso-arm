#!/bin/sh
# Valve's Steam client for Linux under tso-arm, as far as it gets without logging in: 'tso-arm steam' (Valve's
# launcher package from repo.steampowered.com, checked against Valve's package index, unpacked, not installed) on an
# X server without a screen (Xvfb), for at most STEAM_MINUTES. It records how far Steam got (the bootstrap unpacked,
# the client downloaded and unpacked, steamwebhelper started, its window, Steam's login window) with screenshots, the
# windows and processes, and Steam's logs. Needs the root file system ('tso-arm rootfs'), Xvfb, xwininfo (x11-utils),
# import (ImageMagick); dbus-launch where there is one.
#   tests/steam_check.sh NAME [OPTIONS of tso-arm run]        STEAM_ENV=TSO_ARM_THUNKS=1 tests/steam_check.sh gpu
#   STEAM_RAW=1: the launcher with 'tso-arm run' and these OPTIONS instead, without the settings 'tso-arm steam' makes
#   STEAM_MINUTES (default 20); STEAM_KEEP=1 keeps the Steam installation of an earlier run (~/.local/share/Steam);
#   STEAM_ARGS: options for Steam (-cef-...); STEAM_ENV: options of env for it (NAME=VALUE, -u NAME); STEAM_STRACE=1:
#   the system calls of every process that failed, and how each process ended, as the host's strace sees them (FEX's
#   own), into strace.txt
# Into build/steam/NAME: summary.md (the stages with the second each was reached, the first errors), console.txt
# (stdout and stderr of the launcher and what it started), logs/ (Steam's), shot-SSSS.png, windows-SSSS.txt and
# ps-SSSS.txt (with the sockets of FEX's server) every 30 seconds. Exit status 0 when it ran; how far Steam got is in
# summary.md.
set -e
cd "$(dirname "$0")/.."
R=$PWD
name=${1:?usage: tests/steam_check.sh NAME [OPTIONS of tso-arm run]}
shift
opts="$*"
O=$R/build/steam/$name
rm -rf "$O"
mkdir -p "$O/logs"
min=${STEAM_MINUTES:-20}
T=$R/bin/tso-arm
S=$HOME/.local/share/Steam
say() { echo "steam_check: $*"; }

# Valve's launcher package, as 'tso-arm steam' fetches it
export TSO_ARM_STEAM_DIR=$R/build/steam/launcher
"$T" steam install
L=$TSO_ARM_STEAM_DIR/current
if [ "${STEAM_KEEP:-0}" != 1 ]; then
    rm -rf "$S" "$HOME/.steam"
fi

# what a container runtime (pressure-vessel's bubblewrap) needs: user namespaces, which AppArmor may restrict
{
    if [ "${STEAM_RAW:-0}" = 1 ]; then
        echo "# Steam under tso-arm: $name (tso-arm run${opts:+ $opts} bin_steam.sh${STEAM_ENV:+, env $STEAM_ENV})"
    else
        echo "# Steam under tso-arm: $name (tso-arm steam${STEAM_ENV:+, env $STEAM_ENV})"
    fi
    echo
    echo '```'
    "$T" version
    echo "steam-launcher $(cat "$L/VERSION"), $(date -u '+%Y-%m-%d %H:%M UTC'), at most $min minutes"
    for k in kernel.apparmor_restrict_unprivileged_userns kernel.unprivileged_userns_clone user.max_user_namespaces; do
        v=$(sysctl -n $k 2>/dev/null) && echo "$k = $v"
    done
    unshare -Ur true 2>/dev/null && echo "user namespace: can be made" || echo "user namespace: cannot be made (unshare -Ur)"
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        [ -d "$XDG_RUNTIME_DIR" ] && echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" || echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR (no such directory)"
    else
        echo "XDG_RUNTIME_DIR unset"
    fi
    [ -f /proc/sys/fs/binfmt_misc/tso-arm ] && echo "binfmt_misc: $(sed -n 's/^interpreter //p' /proc/sys/fs/binfmt_misc/tso-arm) ($(sed -n 's/^flags: //p' /proc/sys/fs/binfmt_misc/tso-arm))" ||
        echo "binfmt_misc: tso-arm not registered"
    # FEX itself (no server running yet) with an XDG_RUNTIME_DIR that names no directory, and tso-arm run so
    F=$HOME/.local/opt/tso-arm/bin/FEX
    if [ -x "$F" ]; then
        o=$(XDG_RUNTIME_DIR=/nonexistent/run "$F" /bin/true 2>&1) && s=0 || s=$?
        echo "FEX /bin/true, XDG_RUNTIME_DIR=/nonexistent/run: exit status $s $(echo "$o" | tail -n 1)"
        sleep 2
        printf '#!/bin/sh\necho "$(uname -m) from a script"\n' >"$O/script.sh"
        chmod +x "$O/script.sh"
        o=$(XDG_RUNTIME_DIR=/nonexistent/run "$T" run "$O/script.sh" 2>&1) && s=0 || s=$?
        echo "tso-arm run SCRIPT, XDG_RUNTIME_DIR=/nonexistent/run: exit status $s $(echo "$o" | tail -n 1)"
        sleep 2
    fi
    # the threads a program of one thread sees in /proc/self/task under tso-arm (Chromium's zygote forks with one
    # only), with FEX's disk cache and without (tests/singlethread.c, built by the workflow)
    if [ -x "$R/build/steam/singlethread" ]; then
        for c in 1 0; do
            o=$(TSO_ARM_DISKCACHE=$c "$T" run "$R/build/steam/singlethread" 2>&1) && s=0 || s=$?
            echo "TSO_ARM_DISKCACHE=$c: $o (exit status $s)"
        done
        sleep 2
    fi
    # Chromium's way of forking its children (tests/forkstack.c), under the page protocol and FEX's full ordering
    if [ -x "$R/build/steam/forkstack" ]; then
        for m in tso full; do
            o=$("$T" run --mode $m "$R/build/steam/forkstack" 50 2>&1 | tail -n 1) && s=0 || s=$?
            echo "--mode $m: $o"
        done
        sleep 2
    fi
    # what a process in user, network and PID namespaces of its own (Chromium's sandbox) sees of XDG_RUNTIME_DIR
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        : >"$XDG_RUNTIME_DIR/steam-check-probe"
        o=$(unshare --user --map-current-user --net --pid --fork sh -c "ls -ld '$XDG_RUNTIME_DIR' && ls '$XDG_RUNTIME_DIR' | head -n 5" 2>&1 | tr '\n' ' ') || true
        echo "in new user (uid kept), network and PID namespaces: $o"
        o=$(unshare -Urnp --fork sh -c "ls -ld '$XDG_RUNTIME_DIR' && ls '$XDG_RUNTIME_DIR' | head -n 5" 2>&1 | tr '\n' ' ') || true
        echo "the same as root of the user namespace: $o"
        rm -f "$XDG_RUNTIME_DIR/steam-check-probe"
    fi
    echo '```'
} >"$O/summary.md"

# an X server without a screen, and a session bus
D=:${STEAM_DISPLAY:-99}
Xvfb $D -screen 0 1280x800x24 -nolisten tcp >"$O/xvfb.txt" 2>&1 &
xpid=$!
export DISPLAY=$D
i=0
until xwininfo -root >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -lt 40 ] || {
        say "Xvfb did not start"
        cat "$O/xvfb.txt"
        exit 1
    }
    sleep 0.5
done
if command -v dbus-launch >/dev/null; then
    eval "$(dbus-launch --sh-syntax)"
fi

# Steam, in a session of its own (for stopping all of it at the end)
start=$(date +%s)
wrap=""
if [ "${STEAM_STRACE:-0}" = 1 ]; then
    wrap="strace -f -q --seccomp-bpf -e status=!successful -e signal=none -e trace=%process,%memory,%ipc,%network,%signal -o $O/strace.txt"
fi
if [ "${STEAM_RAW:-0}" = 1 ]; then
    set -- run $opts "$L/usr/lib/steam/bin_steam.sh"
else
    set -- steam
fi
setsid $wrap env ${STEAM_ENV:-} "$T" "$@" ${STEAM_ARGS:-} >"$O/console.txt" 2>&1 </dev/null &
pid=$!
say "started: ${wrap:+$wrap }${STEAM_ENV:+env $STEAM_ENV }tso-arm $* ${STEAM_ARGS:-}(session $pid), at most $min minutes"

# the stages, each with the second it was first seen
stages=""
: >"$O/stages.txt"
reached() {
    case " $stages " in *" $1 "*) return 0 ;; esac
    return 1
}
mark() {
    reached "$1" && return 0
    stages="$stages $1"
    echo "$1 $2" >>"$O/stages.txt"
    say "$(printf '%4d s' "$2"): $1"
}
shown=0
while :; do
    now=$(($(date +%s) - start))
    tag=$(printf '%04d' $now)
    {
        ps -eo pid,ppid,etimes,rss,args
        echo "FEX's server sockets:"
        ls -la "${XDG_RUNTIME_DIR:-/nonexistent}" "${TMPDIR:-/tmp}" 2>&1 | grep -i 'fex\|^/\|cannot'
    } >"$O/ps-$tag.txt" 2>/dev/null || true
    xwininfo -root -tree >"$O/windows-$tag.txt" 2>/dev/null || true
    import -window root "$O/shot-$tag.png" 2>/dev/null || true
    [ -x "$S/steam.sh" ] && mark bootstrap $now
    ls "$S"/package/*.zip* >/dev/null 2>&1 && mark client-download $now
    [ -f "$S/ubuntu12_32/steamclient.so" ] && mark client-unpacked $now
    [ -d "$S/ubuntu12_64/steam-runtime-steamrt" ] && mark runtime-unpacked $now
    grep -q 'ubuntu12_32/steam ' "$O/ps-$tag.txt" && mark client-running $now
    grep -q 'steamwebhelper' "$O/ps-$tag.txt" && mark steamwebhelper $now
    awk '{ print $5 }' "$O/ps-$tag.txt" | grep -q 'pressure-vessel\|pv-bwrap\|srt-bwrap' && mark container $now
    # windows (xwininfo: 0x200007 "Title": ("instance" "class")  1280x800+0+0): the 32-bit client's own (its
    # updater), and steamwebhelper's of 200 by 200 pixels or more (it keeps small hidden ones as well)
    grep -q '("steam" "steam")' "$O/windows-$tag.txt" && mark client-window $now
    # (its first window, 200 by 200 pixels, waits for the page to draw)
    if awk '/\("steamwebhelper"/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+[+-]/) {
            split($i, a, /[x+-]/); if (a[1] > 300 && a[2] > 300) f = 1 } } END { exit !f }' "$O/windows-$tag.txt"; then
        mark webhelper-window $now
        shown=$((shown + 1))
    fi
    grep -qi '"[^"]*sign in[^"]*"' "$O/windows-$tag.txt" && mark login-window $now
    # once steamwebhelper has shown a window of its own for a minute, or Steam ended, or the time is up
    [ $shown -ge 3 ] && break
    kill -0 $pid 2>/dev/null || {
        mark ended $now
        break
    }
    [ $now -lt $((min * 60)) ] || {
        mark time-up $now
        break
    }
    sleep 30
done
kill -TERM -- -$pid 2>/dev/null || true
pkill -TERM -s $pid 2>/dev/null || true
sleep 5
kill -KILL -- -$pid 2>/dev/null || true
pkill -KILL -s $pid 2>/dev/null || true
wait $pid 2>/dev/null && s=0 || s=$?
kill $xpid 2>/dev/null || true
[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true

# Steam's logs, and what came first that went wrong
cp -R "$S/logs/." "$O/logs/" 2>/dev/null || true
for f in "$S"/error.log "$S"/ubuntu12_32/steam-runtime/*.log; do
    [ -f "$f" ] && cp "$f" "$O/logs/" || true
done
{
    echo
    echo "| stage | second |"
    echo "|---|---|"
    while read -r st sec; do echo "| $st | $sec |"; done <"$O/stages.txt"
    echo
    echo "Windows at the end:"
    echo
    echo '```'
    grep -o '"[^"]*"' "$(ls "$O"/windows-*.txt | tail -n 1)" | sort | uniq -c | sort -rn | head -n 20
    echo '```'
    echo
    echo "First messages of note (console.txt and Steam's logs):"
    echo
    echo '```'
    cat "$O/console.txt" "$O"/logs/*.txt 2>/dev/null |
        grep -iE 'error|fail|cannot|can.t|not found|unable|abort|crash|signal|denied|unsupported' | head -n 40
    echo '```'
    echo
    if [ -f "$O/strace.txt" ]; then
        echo "System calls that failed (strace -f -Z: name, error, how often):"
        echo
        echo '```'
        sed -n 's/^[0-9][0-9]* *\([a-z0-9_]*\)(.*= -1 \([A-Z0-9]*\).*/\1 \2/p' "$O/strace.txt" | sort | uniq -c | sort -rn | head -n 30
        echo '```'
        echo
        echo "How processes ended other than with exit status 0 (how often):"
        echo
        echo '```'
        grep -E '\+\+\+ (killed by|exited with [1-9])|exit_group\([1-9]' "$O/strace.txt" | sed 's/^[0-9]* *//' | sort | uniq -c | sort -rn | head -n 20
        echo '```'
        echo
        echo "Signals sent (kill, tgkill; the first 20):"
        echo
        echo '```'
        grep -E '^[0-9]+ +(kill|tgkill|tkill)\(' "$O/strace.txt" | grep -v ', 0)' | head -n 20 | cut -c1-200
        echo '```'
        echo
        echo "Of them clone, clone3, fork, vfork (the first 20):"
        echo
        echo '```'
        grep -E '^[0-9]+ +(clone|clone3|fork|vfork)\(' "$O/strace.txt" | head -n 20 | cut -c1-300
        echo '```'
        echo
        gzip -9 "$O/strace.txt"
    fi
    echo "Last lines of console.txt:"
    echo
    echo '```'
    tail -n 30 "$O/console.txt"
    echo '```'
} >>"$O/summary.md"
# screenshots: keep every second one besides the last, so the artifact stays small
n=0
for p in "$O"/shot-*.png; do
    n=$((n + 1))
    [ $((n % 2)) = 0 ] || [ "$p" = "$(ls "$O"/shot-*.png | tail -n 1)" ] || rm -f "$p"
done
cat "$O/summary.md"

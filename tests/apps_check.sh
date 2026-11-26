#!/bin/sh
# x86 desktop programs that have no Arm build for Linux, as a user gets them: 'tso-arm app install NAME' (from their
# makers' own addresses), then 'tso-arm app run NAME' on an X server without a screen (Xvfb), up to its first window of
# 300 by 300 pixels or more and until it draws in it (once more where the first start only fetched what the program
# runs: Discord), for at most APPS_MINUTES each. Signing in is not tested. Needs the root file system
# ('tso-arm rootfs', writable: the programs go into it), Xvfb, xwininfo (x11-utils), import (ImageMagick);
# dbus-launch where there is one.
#   tests/apps_check.sh [NAME...]     default: every program 'tso-arm app' knows by name
#   APPS_MINUTES (default 5); APPS_EXPECT=window: exit status 1 unless each program drew in a window; APPS_REMOVE=1:
#   at the end every program removed again, and the root file system has to hold the files it held before;
#   APPS_KNOWN: programs known not to draw yet (reported, not counted against APPS_EXPECT)
# Into build/apps: summary.md (each program: its version, the install's seconds, the second of its first window and
# its title), and per program NAME/: install.txt, console.txt, windows-SSSS.txt and shot-SSSS.png every 20 seconds,
# window.png at the first window.
set -e
cd "$(dirname "$0")/.."
R=$PWD
T=$R/bin/tso-arm
O=$R/build/apps
rm -rf "$O"
mkdir -p "$O"
min=${APPS_MINUTES:-5}
[ $# -gt 0 ] || set -- discord spotify slack signal zoom edge
say() { echo "apps_check: $*"; }

D=:${APPS_DISPLAY:-98}
Xvfb $D -screen 0 1280x800x24 -nolisten tcp >"$O/xvfb.txt" 2>&1 &
xpid=$!
export DISPLAY=$D
i=0
until xwininfo -root >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -lt 40 ] || {
        say "Xvfb did not start"
        exit 1
    }
    sleep 0.5
done
if command -v dbus-launch >/dev/null; then
    eval "$(dbus-launch --sh-syntax)"
fi

{
    echo "# x86 desktop programs under tso-arm (tso-arm app)"
    echo
    echo '```'
    "$T" version
    echo "$(date -u '+%Y-%m-%d %H:%M UTC'), at most $min minutes each"
    echo '```'
    echo
    echo "| program | version | install | first window | drawn | its title |"
    echo "|---|---|---|---|---|---|"
} >"$O/summary.md"

failed=""
rfs=$("$T" app rootfs)
if [ "${APPS_REMOVE:-0}" = 1 ]; then
    (cd "$rfs" && find . | sort) >"$O/rootfs-before.txt"
fi
for n in "$@"; do
    P=$O/$n
    mkdir -p "$P"
    s=$(date +%s)
    st=0
    "$T" app install "$n" >"$P/install.txt" 2>&1 || st=$?
    inst=$(($(date +%s) - s))
    ver=$("$T" app list 2>/dev/null | awk -v n="$n" '$1 == n { print $3 }')
    if [ $st != 0 ]; then
        say "$n: the install failed (exit status $st)"
        tail -n 5 "$P/install.txt"
        echo "| $n | - | failed | - | - | - |" >>"$O/summary.md"
        failed="$failed $n"
        continue
    fi
    say "$n $ver installed in $inst s"
    # a second start for a program whose first fetches what it runs (Discord's starter) and then shows nothing
    for attempt in 1 2; do
        # the windows there before it (none but the root's own, usually)
        xwininfo -root -tree 2>/dev/null | grep -o '^ *0x[0-9a-f]*' | tr -d ' ' | sort >"$P/before.txt"
        setsid "$T" app run "$n" >>"$P/console.txt" 2>&1 </dev/null &
        pid=$!
        start=$(date +%s)
        win="" title="" drawn=""
        while :; do
            now=$(($(date +%s) - start))
            tag=$(printf '%04d' $now)
            xwininfo -root -tree >"$P/windows-$tag.txt" 2>/dev/null || true
            # a window that was not there before, 300 by 300 pixels or more, with a title (not a starter's setup or
            # update window: Discord's "Discord Setup" while it fetches Discord)
            line=$(grep -v -F -f "$P/before.txt" "$P/windows-$tag.txt" | grep -v '"[^"]*\(Setup\|Updat\|Install\)[^"]*"' | awk '/"[^"]+"/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+[+-]/) {
                split($i, a, /[x+-]/); if (a[1] >= 300 && a[2] >= 300) { print; exit } } }')
            if [ -n "$line" ] && [ -z "$win" ]; then
                win=$now
                title=$(echo "$line" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p' | tr '|' '/')
                say "$n: a window after $win s: $title"
            fi
            if [ -n "$win" ]; then
                # drawn: the screen holds more than one colour (a uniform one compresses to some hundred bytes)
                import -window root "$P/window.png" 2>/dev/null || true
                if [ "$(wc -c <"$P/window.png" 2>/dev/null || echo 0)" -gt 20000 ]; then
                    drawn=$now
                    say "$n: drawn after $drawn s"
                    break
                fi
                [ $((now - win)) -lt 90 ] || {
                    say "$n: its window drew nothing in 90 s"
                    break
                }
            elif [ $((now % 20)) -lt 5 ]; then
                import -window root "$P/shot-$tag.png" 2>/dev/null || true
            fi
            kill -0 $pid 2>/dev/null || {
                say "$n ended after $now s${win:+ (a window at $win s)}"
                break
            }
            [ $now -lt $((min * 60)) ] || {
                say "$n: no window in $min minutes"
                break
            }
            sleep 5
        done
        kill -TERM -- -$pid 2>/dev/null || true
        pkill -TERM -s $pid 2>/dev/null || true
        sleep 3
        kill -KILL -- -$pid 2>/dev/null || true
        pkill -KILL -s $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        [ -n "$drawn" ] && break
        [ $attempt = 1 ] && say "$n: started once more"
    done
    # only every fourth screenshot of the way there
    k=0
    for p in "$P"/shot-*.png; do
        [ -f "$p" ] || continue
        k=$((k + 1))
        [ $((k % 4)) = 0 ] || rm -f "$p"
    done
    if [ -n "$drawn" ]; then
        echo "| $n | $ver | $inst s | $win s | $drawn s | $title |" >>"$O/summary.md"
    else
        case " ${APPS_KNOWN:-} " in
        *" $n "*) echo "| $n | $ver | $inst s | ${win:-none}${win:+ s} | no (known) | ${title:--} |" >>"$O/summary.md" ;;
        *)
            echo "| $n | $ver | $inst s | ${win:-none}${win:+ s} | no | ${title:--} |" >>"$O/summary.md"
            failed="$failed $n"
            ;;
        esac
        {
            echo
            echo "$n, last lines of its output:"
            echo
            echo '```'
            grep -v '^$' "$P/console.txt" | tail -n 15
            echo '```'
        } >>"$O/summary.md.tail"
    fi
done
kill $xpid 2>/dev/null || true
[ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null || true
if [ "${APPS_REMOVE:-0}" = 1 ]; then
    for n in $("$T" app list | awk '{ print $1 }'); do
        "$T" app remove "$n" >>"$O/remove.txt" 2>&1 || failed="$failed remove-$n"
    done
    (cd "$rfs" && find . | sort) >"$O/rootfs-after.txt"
    if cmp -s "$O/rootfs-before.txt" "$O/rootfs-after.txt"; then
        printf '\nAll removed again (tso-arm app remove): the root file system holds the files it held before.\n' >>"$O/summary.md"
    else
        {
            printf '\nAll removed again (tso-arm app remove), but the root file system differs from before:\n\n```\n'
            diff "$O/rootfs-before.txt" "$O/rootfs-after.txt" | head -n 20
            printf '```\n'
        } >>"$O/summary.md"
        failed="$failed remove"
    fi
fi
[ -f "$O/summary.md.tail" ] && cat "$O/summary.md.tail" >>"$O/summary.md" && rm -f "$O/summary.md.tail"
cat "$O/summary.md"
if [ "${APPS_EXPECT:-}" = window ] && [ -n "$failed" ]; then
    say "no window from:$failed"
    exit 1
fi
exit 0

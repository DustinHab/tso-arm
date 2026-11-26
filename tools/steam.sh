#!/bin/sh
# Steam for tso-arm (what 'tso-arm steam' runs): Valve's Steam client for Linux through tso-arm. Valve's launcher
# package (steam-launcher from repo.steampowered.com) is checked against Valve's package index and unpacked into
# tso-arm's data directory, not installed into the system; its bootstrap puts the client into ~/.local/share/Steam
# as on an x86 computer, and the client updates itself from Valve's servers from then on.
#   tools/steam.sh install     fetch the newest launcher package
#   tools/steam.sh [ARGS]      start Steam with ARGS (fetches the launcher first if there is none)
# TSO_ARM_STEAM_DIR: where the launcher is kept (default ~/.local/share/tso-arm/steam)
set -e
R=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
D=${TSO_ARM_STEAM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/tso-arm/steam}
REPO=https://repo.steampowered.com/steam
say() { echo "tso-arm steam: $*" >&2; }
die() {
    say "$*"
    exit 1
}

if command -v curl >/dev/null; then
    get() { curl -fsSL --retry 2 -o "$2" "$1"; }
elif command -v wget >/dev/null; then
    get() { wget -q -O "$2" "$1"; }
else
    get() { die "needs curl or wget"; }
fi
. "$R/tools/undeb.sh"

install_launcher() {
    t=$(mktemp -d)
    trap 'rm -rf "$t"' EXIT
    say "reading Valve's package index"
    get "$REPO/dists/stable/steam/binary-amd64/Packages" "$t/p" || die "no connection to repo.steampowered.com"
    set -- $(pick "$t/p" steam-launcher)
    [ $# = 3 ] || die "Valve's index has no steam-launcher"
    ver=$1
    # (without its epoch, "1:", in the directory's name: a colon would end it in PATH)
    dir=${ver#*:}
    if [ -f "$D/current/usr/lib/steam/bin_steam.sh" ] && [ "$(cat "$D/current/VERSION" 2>/dev/null)" = "$ver" ]; then
        say "steam-launcher $ver is installed ($D/current)"
        return
    fi
    say "fetching steam-launcher $ver"
    get "$REPO/$2" "$t/s.deb" || die "could not fetch $REPO/$2"
    [ "$(sha256sum "$t/s.deb" | cut -d' ' -f1)" = "$3" ] || die "$2 does not match Valve's index"
    rm -rf "$D/$dir.new"
    mkdir -p "$D/$dir.new"
    undeb "$t/s.deb" "$D/$dir.new"
    [ -f "$D/$dir.new/usr/lib/steam/bin_steam.sh" ] || die "the package held no usr/lib/steam/bin_steam.sh"
    echo "$ver" >"$D/$dir.new/VERSION"
    rm -rf "$D/$dir"
    mv "$D/$dir.new" "$D/$dir"
    ln -sfn "$dir" "$D/current"
    say "steam-launcher $ver unpacked into $D/$dir"
}

case ${1:-} in
install)
    install_launcher
    exit 0
    ;;
esac
[ "$(id -u)" != 0 ] || die "Steam does not run as root"
[ -f "$D/current/usr/lib/steam/bin_steam.sh" ] || install_launcher

# Steam requires user namespaces (its requirements check runs bubblewrap, steamwebhelper's sandbox makes them)
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ] && [ ! -f /etc/apparmor.d/tso-arm-fex ]; then
    die "Steam requires user namespaces, which AppArmor restricts here, FEX's as well: 'sudo tso-arm userns allow' allows them to tso-arm's FEX alone"
fi
# FEX's disk cache off: its writer is a second thread in every process, and Chromium's zygote (steamwebhelper's)
# forks only with one ('Check failed: IsSingleThreaded'), so steamwebhelper started no GPU process and drew nothing
export TSO_ARM_DISKCACHE=${TSO_ARM_DISKCACHE:-0}
# FEX's full ordering: under the page protocol the processes steamwebhelper's zygote forks (renderer, GPU, network)
# ended within seconds, and it drew nothing (games Steam starts inherit this as well)
export TSO_ARM_MODE=${TSO_ARM_MODE:-full}
# FEX's server socket in the home directory, as Valve's build of FEX for Steam has it: steamwebhelper runs in Steam's
# runtime container, which has an XDG_RUNTIME_DIR of its own, and its sandboxed zygote in a network namespace of its
# own; there FEX reached neither its abstract socket nor the one in XDG_RUNTIME_DIR ("Couldn't connect to FEXServer
# socket") and did not start
if [ -z "${FEX_SERVERSOCKETPATH:-}" ]; then
    s=${XDG_CACHE_HOME:-$HOME/.cache}/tso-arm/server/$(id -u).FEXServer.Socket
    if [ ${#s} -lt 108 ]; then
        # one server per user: one with the usual sockets (x86 programs started otherwise) keeps this one from
        # starting; it ends a second after its last program
        foreign() {
            for p in $(pgrep -u "$(id -u)" -x FEXServer 2>/dev/null); do
                tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qx "FEX_SERVERSOCKETPATH=$s" || return 0
            done
            return 1
        }
        i=0
        while foreign && [ $i -lt 4 ]; do
            sleep 1
            i=$((i + 1))
        done
        foreign && die "x86 programs run through tso-arm already (FEX's server for them); Steam starts once they have ended"
        mkdir -p "$(dirname "$s")"
        export FEX_SERVERSOCKETPATH="$s"
    fi
fi
# steamwebhelper without Chromium's sandbox: with it, under full ordering as well, it showed no window
# (TSO_ARM_STEAM_SANDBOX=1 keeps it)
[ "${TSO_ARM_STEAM_SANDBOX:-0}" = 1 ] || set -- -cef-disable-sandbox "$@"
exec "$R/bin/tso-arm" run "$D/current/usr/lib/steam/bin_steam.sh" "$@"

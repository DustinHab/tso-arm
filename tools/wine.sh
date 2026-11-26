#!/bin/sh
# Wine for tso-arm (what 'tso-arm wine' runs): WineHQ's own build for Ubuntu 24.04, the same distribution as the root
# file system 'tso-arm rootfs' fetches, unpacked into tso-arm's data directory; then Windows programs through it.
#   tools/wine.sh install [VERSION]   fetch it (the newest stable without VERSION), checked against WineHQ's index
#   tools/wine.sh PROGRAM.exe ARGS    run a Windows program (installs Wine first if there is none)
#   tools/wine.sh                     which Wine is installed
# WINEPREFIX as Wine has it (~/.wine); TSO_ARM_WINE_DIR: where Wine is kept.
set -e
R=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
D=${TSO_ARM_WINE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/tso-arm/wine}
REPO=https://dl.winehq.org/wine-builds/ubuntu
say() { echo "tso-arm wine: $*" >&2; }
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

# undeb (the data of a .deb) and pick (a package's newest version in an index)
. "$R/tools/undeb.sh"

install_wine() {
    want=${1:-}
    t=$(mktemp -d)
    trap 'rm -rf "$t"' EXIT
    say "reading WineHQ's index for Ubuntu 24.04"
    get "$REPO/dists/noble/main/binary-amd64/Packages.gz" "$t/p64.gz" || die "no connection to dl.winehq.org"
    get "$REPO/dists/noble/main/binary-i386/Packages.gz" "$t/p32.gz" || die "no connection to dl.winehq.org"
    gzip -d "$t/p64.gz" "$t/p32.gz"
    set -- $(pick "$t/p64" wine-stable-amd64 "$want")
    [ $# = 3 ] || die "no wine-stable ${want:-at all} for Ubuntu 24.04 at WineHQ"
    ver=$1
    [ -x "$D/$ver/opt/wine-stable/bin/wine" ] && {
        ln -sfn "$ver" "$D/current"
        say "Wine $ver is installed ($D/$ver)"
        return
    }
    mkdir -p "$D/$ver.new"
    for pkg in wine-stable-amd64:p64 wine-stable:p64 wine-stable-i386:p32; do
        set -- $(pick "$t/${pkg#*:}" "${pkg%:*}" "$ver")
        [ $# = 3 ] && [ "$1" = "$ver" ] || die "WineHQ's index has no ${pkg%:*} $ver"
        say "fetching ${pkg%:*} $ver"
        get "$REPO/$2" "$t/p.deb" || die "could not fetch $REPO/$2"
        [ "$(sha256sum "$t/p.deb" | cut -d' ' -f1)" = "$3" ] || die "$2 does not match WineHQ's index"
        undeb "$t/p.deb" "$D/$ver.new"
        rm -f "$t/p.deb"
    done
    [ -x "$D/$ver.new/opt/wine-stable/bin/wine" ] || die "the packages held no opt/wine-stable/bin/wine"
    rm -rf "$D/$ver"
    mv "$D/$ver.new" "$D/$ver"
    ln -sfn "$ver" "$D/current"
    say "Wine $ver installed into $D/$ver"
}

case ${1:-} in
install)
    shift
    install_wine "$@"
    ;;
"")
    if [ -x "$D/current/opt/wine-stable/bin/wine" ]; then
        echo "Wine $(readlink "$D/current") in $D/current"
    else
        echo "no Wine yet: 'tso-arm wine install', or 'tso-arm wine PROGRAM.exe' installs it on first use"
    fi
    ;;
*)
    [ -x "$D/current/opt/wine-stable/bin/wine" ] || install_wine
    # Windows programs open windows; Wine's own debug channels stay quiet unless WINEDEBUG says otherwise
    export WINEDEBUG=${WINEDEBUG:--all}
    # The page protocol, as for any program (TSO_ARM_MODE=full: FEX's full ordering). Until 0.4.5 Wine ran with full
    # ordering: under the views its processes read wineserver's session memory as it was when they mapped it, and
    # explorer.exe got no desktop (notes section 59)
    exec "$R/bin/tso-arm" run "$D/current/opt/wine-stable/bin/wine" "$@"
    ;;
esac

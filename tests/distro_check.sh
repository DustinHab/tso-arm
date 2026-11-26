#!/bin/sh
# The one-line installation and a first run in a container of a distribution's own image, as it comes, on a 64-bit
# Arm machine with docker (or podman as docker); the distributions workflow runs it for each (docs/GUIDE.md lists them).
#   tests/distro_check.sh IMAGE [EXPECT]
# EXPECT: nothing (tso-arm installs and runs there), musl or old-glibc (the installer stops and says why, nothing is
# installed). Needs the release package of this checkout (dist/tso-arm-VERSION-linux-arm64.tar.gz, tools/package.sh)
# and the x86 test programs in build/distros: threads, mp (litmus), threads32 and mp32 (32-bit), linked statically,
# and threads-dyn, linked dynamically. In the container, as root:
#   1. tools/get.sh piped into sh as the README's curl does: it installs, or stops and names the command that
#      installs what is missing; that command runs, without questions
#   2. the same with curl: the newest release from GitHub, into /opt/tso-arm
#   3. the package of this checkout over it; tso-arm version, check, run (threads, litmus tests without a forbidden
#      outcome, 32-bit programs, a dynamically linked one without a root file system), report, rootfs without its
#      tools (it names them; that command runs), uninstall
# and step 3 again as a user without privileges (~/.local/share/tso-arm), without rootfs. Where the installer is to
# stop, the package's statically linked FEX alone runs the static programs afterwards, for the record. Exit status 1
# if something failed.
cd "$(dirname "$0")/.."
fail() {
    echo "FAIL: $*"
    exit 1
}
ok() { echo "ok:   $*"; }
show() { printf '%s\n' "$1" | sed 's/^/      | /'; }

if [ "$1" != --inside ]; then
    img=$1
    expect=${2:-runs}
    [ -n "$img" ] || fail "usage: tests/distro_check.sh IMAGE [musl | old-glibc]"
    pkg=dist/tso-arm-$(cat VERSION)-linux-arm64.tar.gz
    [ -f "$pkg" ] || fail "no release package $pkg (tools/package.sh)"
    for p in threads mp threads32 mp32 threads-dyn; do
        [ -x build/distros/$p ] || fail "no test program build/distros/$p"
    done
    D=${DOCKER:-docker}
    c=tso-arm-distro-$$
    $D run -d --name $c --platform linux/arm64 -v "$PWD:/src:ro" "$img" tail -f /dev/null >/dev/null ||
        fail "$D run $img"
    trap '$D rm -f $c >/dev/null 2>&1' EXIT
    $D exec -e PKG="/src/$pkg" $c sh /src/tests/distro_check.sh --inside root "$expect" || exit 1
    [ "$expect" = runs ] || exit 0
    $D exec $c sh -c 'useradd -m tester 2>/dev/null || adduser -D tester' || fail "no user added"
    $D exec -u tester -e HOME=/home/tester -w /home/tester -e PKG="/src/$pkg" $c \
        sh /src/tests/distro_check.sh --inside user || exit 1
    exit 0
fi

B=/src/build/distros
step=$2
expect=${3:-runs}
. /etc/os-release
echo "== $PRETTY_NAME ($(uname -m)), as $(id -un)"

# The command a message of tso-arm's names on its own indented line ("  apt-get install curl"), run without questions;
# WHAT says what the message was about. Fails if there is none or it fails.
named() {
    cmd=$(printf '%s\n' "$1" | sed -n 's/^  \([a-z].*\(install\|apk add\).*\)$/\1/p' | tail -n 1)
    [ -n "$cmd" ] || fail "$2: no command named to install what is missing"
    ok "$2: it names $cmd"
    cmd=$(echo "$cmd" | sed 's/apt-get install/apt-get install -y -q/; s/\(dnf\|yum\) install/\1 install -y -q/;
        s/zypper install/zypper -n -q install/; s/pacman -S/pacman -S --noconfirm/')
    if log=$(DEBIAN_FRONTEND=noninteractive sh -c "$cmd" 2>&1); then
        ok "installed with: $cmd"
        return
    fi
    # once more with the package lists fetched anew: a distribution's mirrors change under a run (zypper said once
    # only "Installation has completed with error" on Tumbleweed, whose snapshots come several times a day)
    show "$(echo "$log" | tail -n 40)"
    case $cmd in
    *zypper*) zypper -n -q refresh >/dev/null 2>&1 ;;
    *apt-get*) apt-get update -qq >/dev/null 2>&1 ;;
    *dnf*) dnf -q -y makecache >/dev/null 2>&1 ;;
    esac
    log=$(DEBIAN_FRONTEND=noninteractive sh -c "$cmd" 2>&1) || {
        show "$(echo "$log" | tail -n 40)"
        fail "$cmd"
    }
    ok "installed with: $cmd (the second time)"
}

# Where the installer stops: whether the statically linked FEX of the package (which binfmt_misc starts in
# containers) runs the static test programs here all the same, started as there; for the record, it fails nothing
static_fex() {
    command -v tar >/dev/null && command -v gzip >/dev/null || {
        echo "      no tar and gzip here: the statically linked FEX not tried"
        return 0
    }
    d=$(mktemp -d)
    tar -xzf "$PKG" -C "$d" && S=$(echo "$d"/tso-arm-*/fex/prebuilt/bin/FEX-static) && [ -x "$S" ] || return 0
    for p in "threads 8" "mp mp 100000" "threads32 8" "mp32 mp 100000"; do
        o=$(TSO_ARM_HANDOVER=1 timeout 300 "$S" $B/$p 2>&1) && s=0 || s=$?
        echo "      statically linked FEX alone, $p: exit status $s, $(printf '%s\n' "$o" | tail -n 1)"
    done
    rm -rf "$d"
}

# what tso-arm says and does once installed; T is the command
checks() {
    out=$($T version) || fail "tso-arm version: $out"
    show "$out"
    echo "$out" | grep -q '^FEX: .*patches' || fail "tso-arm version names no FEX"
    ok "tso-arm version"
    out=$($T check)
    show "$out"
    [ "$(echo "$out" | tail -n 1)" = "=> tso-arm can run here" ] || fail "tso-arm check"
    ok "tso-arm check"
    out=$($T run $B/threads 8 | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "threads 8: $out"
    ok "threads 8: $out"
    for v in mp vec rep lb; do
        out=$($T run $B/mp $v 100000) || fail "litmus $v: $out"
        ok "litmus $v: $(echo "$out" | tail -n 1)"
    done
    out=$($T run $B/threads32 8 | tail -n 1)
    echo "$out" | grep -q 'wrong 0' || fail "32-bit threads 8: $out"
    ok "32-bit threads 8: $out"
    out=$($T run $B/mp32 mp 100000) || fail "32-bit litmus mp: $out"
    ok "32-bit litmus mp: $(echo "$out" | tail -n 1)"
    # a dynamically linked program, before 'tso-arm rootfs': it says what to do
    s=0
    out=$($T run $B/threads-dyn 4 2>&1) || s=$?
    [ $s != 0 ] && echo "$out" | grep -q "'tso-arm rootfs' fetches one" || fail "dynamically linked, no root file system: $out"
    ok "dynamically linked, no root file system: $out"
    out=$($T report $B/threads 4)
    show "$out"
    echo "$out" | grep -q "^system: $PRETTY_NAME, kernel .*, glibc 2\.[0-9]*$" || fail "tso-arm report: no system line"
    echo "$out" | grep -q -- '--mode tso: exit status 0' || fail "tso-arm report: the program did not run"
    ok "tso-arm report"
}

if [ "$step" = root ]; then
    # 1. as the image comes
    s=0
    out=$(cat /src/tools/get.sh | sh 2>&1) || s=$?
    show "$out"
    case $expect in
    musl | old-glibc)
        [ $s != 0 ] || fail "the installer did not stop"
        [ ! -e /opt/tso-arm ] && [ ! -e /usr/local/bin/tso-arm ] || fail "the installer left files behind"
        case $expect in
        musl) echo "$out" | grep -q 'has the musl C library' || fail "the installer did not name musl" ;;
        old-glibc) echo "$out" | grep -q 'has glibc 2\.[0-9]*; the prebuilt FEX needs 2.35 or newer' || fail "the installer did not name glibc" ;;
        esac
        ok "the installer stops: $(echo "$out" | head -n 1)"
        static_fex
        exit 0
        ;;
    esac
    if [ $s != 0 ]; then
        [ ! -e /opt/tso-arm/current ] || fail "the installer stopped and left an installation"
        named "$out" "the installer stops"
    else
        ok "the installer installs as the image comes"
    fi
    # 2. the README's line, the newest release from GitHub
    s=0
    if command -v curl >/dev/null; then
        out=$(curl -fsSL file:///src/tools/get.sh | sh 2>&1) || s=$?
    else
        out=$(cat /src/tools/get.sh | sh 2>&1) || s=$?
    fi
    show "$out"
    [ $s = 0 ] && [ -L /opt/tso-arm/current ] && [ -L /usr/local/bin/tso-arm ] || fail "the newest release from GitHub"
    ok "the newest release from GitHub: $(tso-arm version | head -n 1)"
    # 3. this checkout's package over it
    out=$(cat /src/tools/get.sh | TSO_ARM_TARBALL=$PKG sh 2>&1) || fail "installed from $PKG: $out"
    show "$out"
    [ "$(cksum </opt/tso-arm/current/bin/tso-arm)" = "$(cksum </src/bin/tso-arm)" ] || fail "the installation is not this checkout's"
    ok "installed from $PKG into /opt/tso-arm"
    T=tso-arm
    checks
    # 'tso-arm rootfs' where its tools are missing (not fetched here: about 1 GB from FEX's server)
    if ! command -v unsquashfs >/dev/null; then
        s=0
        out=$($T rootfs 2>&1) || s=$?
        show "$out"
        [ $s != 0 ] || fail "tso-arm rootfs without unsquashfs"
        named "$out" "tso-arm rootfs without unsquashfs"
        command -v unsquashfs >/dev/null || fail "no unsquashfs after that"
    fi
    out=$($T uninstall) || fail "tso-arm uninstall: $out"
    show "$out"
    [ ! -e /opt/tso-arm ] && [ ! -e /usr/local/bin/tso-arm ] || fail "tso-arm uninstall left files behind"
    ok "tso-arm uninstall"
else
    out=$(cat /src/tools/get.sh | TSO_ARM_TARBALL=$PKG sh 2>&1) || fail "installed from $PKG: $out"
    show "$out"
    d=$HOME/.local/share/tso-arm
    [ -L "$d/current" ] && [ -L "$HOME/.local/bin/tso-arm" ] || fail "not installed into $d"
    ok "installed from $PKG into $d"
    T=$HOME/.local/bin/tso-arm
    checks
    out=$($T uninstall) || fail "tso-arm uninstall: $out"
    show "$out"
    [ ! -e "$d" ] && [ ! -e "$HOME/.local/bin/tso-arm" ] || fail "tso-arm uninstall left files behind"
    ok "tso-arm uninstall"
fi

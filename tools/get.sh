#!/bin/sh
# Installs tso-arm from its newest release, or updates an installation made this way:
#
#   curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sudo sh
#
# For the user who runs it: into ~/.local/share/tso-arm, the command into ~/.local/bin. As root, for every user: into
# /opt/tso-arm, the command into /usr/local/bin, and x86 programs started directly run through it (binfmt_misc).
# The release package brings FEX prebuilt; nothing is compiled. 'tso-arm update' runs this again.
#   TSO_ARM_VERSION   a version other than the newest (0.4.4)
#   TSO_ARM_TARBALL   a release package downloaded beforehand (tso-arm-VERSION-linux-arm64.tar.gz)
#   TSO_ARM_DEST      another directory than the default for the installation
#   TSO_ARM_BINFMT=0  as root: leave binfmt_misc as it is
# What the system lacks for it (a downloader, tar, awk, a C library the prebuilt FEX runs on) is named before anything
# is fetched, with the command that installs it on this distribution. tso-arm's own messages of that kind come from
# here as well: tools/get.sh --missing WHAT COMMAND... (exit status 1)
set -e
REPO_URL=https://github.com/DustinHab/tso-arm

say() { echo "tso-arm: $*"; }
die() {
    echo "tso-arm: $*" >&2
    exit 1
}
distro=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$ID}")
distro=${distro:-this system}

# The command that installs packages here, for the messages: "sudo apt-get install" and the like (sudo also where
# this runs under sudo; apt-get update before it where apt has no package lists yet, as in a fresh container: Ubuntu's
# images keep them compressed, *_Packages.lz4)
installer() {
    s="sudo "
    [ "$(id -u)" = 0 ] && [ -z "${SUDO_USER:-}" ] && s=""
    if command -v apt-get >/dev/null 2>&1; then
        u=""
        ls /var/lib/apt/lists/*_Packages* >/dev/null 2>&1 || u="${s}apt-get update && "
        echo "${u}${s}apt-get install"
    elif command -v dnf >/dev/null 2>&1; then
        echo "${s}dnf install"
    elif command -v yum >/dev/null 2>&1; then
        echo "${s}yum install"
    elif command -v zypper >/dev/null 2>&1; then
        echo "${s}zypper install"
    elif command -v pacman >/dev/null 2>&1; then
        echo "${s}pacman -S"
    elif command -v apk >/dev/null 2>&1; then
        echo "${s}apk add"
    elif command -v xbps-install >/dev/null 2>&1; then
        echo "${s}xbps-install"
    fi
}
# the package that brings a command or a library, by the name the package manager above knows it by
package() {
    case $1 in
    od | sha256sum | mktemp) echo coreutils ;;
    awk) echo gawk ;;
    unsquashfs) case $(installer) in *zypper*) echo squashfs ;; *) echo squashfs-tools ;; esac ;;
    libstdc++.so.6)
        case $(installer) in
        *apt-get* | *zypper*) echo libstdc++6 ;;
        *pacman*) echo gcc-libs ;;
        *) echo libstdc++ ;;
        esac
        ;;
    libgcc_s.so.1)
        case $(installer) in
        *apt-get*) echo libgcc-s1 ;;
        *zypper*) echo libgcc_s1 ;;
        *pacman*) echo gcc-libs ;;
        *) echo libgcc ;;
        esac
        ;;
    *) echo "$1" ;;
    esac
}
# "a, b and c"
words() {
    w=""
    while [ $# -gt 0 ]; do
        if [ -z "$w" ]; then
            w=$1
        elif [ $# = 1 ]; then
            w="$w and $1"
        else
            w="$w, $1"
        fi
        shift
    done
    echo "$w"
}
# die naming what is missing (commands or libraries) and the command that installs it here
missing() {
    what=$1
    shift
    p=""
    for m in "$@"; do
        n=$(package "$m")
        case " $p " in *" $n "*) ;; *) p="$p $n" ;; esac
    done
    i=$(installer)
    if [ -n "$i" ]; then
        die "$what $(words "$@"), which $distro does not have; install $([ $# = 1 ] && echo it || echo them) with
  $i$p"
    fi
    die "$what $(words "$@"), which $distro does not have (packages:$p)"
}
# a file of CA certificates where the usual distributions keep one (Debian, Alpine, Arch; Fedora; openSUSE)
cacerts() {
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
        [ -s "$f" ] && return 0
    done
    return 1
}
if [ "${1:-}" = --missing ]; then
    shift
    missing "$@"
fi

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] ||
    die "tso-arm runs on 64-bit Arm Linux; this is $(uname -s) on $(uname -m)"

# The C library: the prebuilt FEX is linked against glibc 2.35 (Ubuntu 22.04's) and its C++ library, and starts
# through glibc's dynamic loader
LD=/lib/ld-linux-aarch64.so.1
g=$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')
if [ -z "$g" ] && [ -x "$LD" ]; then
    g=$("$LD" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
fi
if [ -z "$g" ] && ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
    die "$distro has the musl C library; the prebuilt FEX that tso-arm runs on needs glibc 2.35 or newer. In a
container of a distribution with glibc (podman or docker with debian:13 or ubuntu:24.04, for example) this installer
and tso-arm run as they are."
fi
if [ -n "$g" ] && [ "${g%%.*}" -eq 2 ] && [ "${g#*.}" -lt 35 ]; then
    die "$distro has glibc $g; the prebuilt FEX needs 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36 and newer).
On older systems FEX is built from source instead (git, cmake, ninja, clang, lld and python3):
  git clone $REPO_URL && tso-arm/bin/tso-arm install --source"
fi
[ -x "$LD" ] || die "$distro has no glibc dynamic loader ($LD); the prebuilt FEX needs glibc 2.35 or newer"

if [ "$(id -u)" = 0 ]; then
    dest=${TSO_ARM_DEST:-/opt/tso-arm}
    bindir=/usr/local/bin
else
    dest=${TSO_ARM_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/tso-arm}
    bindir=$HOME/.local/bin
fi

# what this script and tso-arm itself use (tso-arm reads a program's ELF header with od and awk)
need=""
for t in tar gzip sha256sum mktemp od awk; do
    command -v $t >/dev/null 2>&1 || need="$need $t"
done
if [ -z "$TSO_ARM_TARBALL" ]; then
    if command -v curl >/dev/null 2>&1; then
        get() { curl -fsSL --retry 2 -o "$2" "$1"; }
        getout() { curl -fsSL --retry 2 "$1"; }
        # where a link leads: GitHub's page of the newest release leads to its tag
        getloc() { curl -fsSL --retry 2 -o /dev/null -w '%{url_effective}' "$1"; }
    elif command -v wget >/dev/null 2>&1; then
        get() { wget -q -O "$2" "$1"; }
        getout() { wget -q -O - "$1"; }
        getloc() { wget -q -O - "$1" | sed -n 's|.*\(/releases/tag/v[0-9][0-9.]*\)".*|\1|p' | head -n 1; }
    else
        need="$need curl"
        cacerts || need="$need ca-certificates"
    fi
fi
[ -z "$need" ] || missing "needs" $need
# GitHub could not be reached: no connection, or no certificates to check its own with
unreachable() {
    if ! cacerts; then
        i=$(installer)
        die "could not reach GitHub ($1): $distro has no CA certificates to check GitHub's with${i:+; install them with
  $i ca-certificates}"
    fi
    die "could not reach GitHub ($1); is there a connection?"
}

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
if [ -n "$TSO_ARM_TARBALL" ]; then
    pkg=$TSO_ARM_TARBALL
    v=$(basename "$pkg" | sed -n 's/^tso-arm-\([0-9][0-9.]*\)-linux-arm64\.tar\.gz$/\1/p')
    [ -n "$v" ] || die "$pkg is not named like a release package (tso-arm-VERSION-linux-arm64.tar.gz)"
else
    v=${TSO_ARM_VERSION:-}
    if [ -z "$v" ]; then
        v=$(getout "https://api.github.com/repos/DustinHab/tso-arm/releases/latest" 2>/dev/null |
            sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)
        # GitHub's API answers 60 requests an hour from one address without a token; its release page does not count
        [ -n "$v" ] || v=$(getloc "$REPO_URL/releases/latest" 2>/dev/null | sed -n 's|.*/releases/tag/v\([0-9][0-9.]*\)$|\1|p')
        [ -n "$v" ] || unreachable "the newest release"
    fi
    if [ -f "$dest/$v/VERSION" ] && [ "$(cat "$dest/$v/VERSION")" = "$v" ] && [ "$(readlink "$dest/current")" = "$v" ]; then
        say "$v is installed already ($dest/$v)"
        exit 0
    fi
    cur=$(readlink "$dest/current" 2>/dev/null || true)
    if [ -z "$TSO_ARM_VERSION" ] && [ -n "$cur" ] && [ "$(printf '%s\n%s\n' "$v" "$cur" | sort -V | tail -n 1)" = "$cur" ]; then
        say "$cur is installed, newer than the newest release ($v); TSO_ARM_VERSION=$v installs that one"
        exit 0
    fi
    pkg=$t/tso-arm-$v-linux-arm64.tar.gz
    say "fetching tso-arm $v"
    if ! get "$REPO_URL/releases/download/v$v/tso-arm-$v-linux-arm64.tar.gz" "$pkg"; then
        getout "$REPO_URL" >/dev/null 2>&1 || unreachable "the package of $v"
        die "no release package for $v"
    fi
    get "$REPO_URL/releases/download/v$v/SHA256SUMS" "$t/SHA256SUMS" || die "no checksums for $v"
    # (BusyBox's sha256sum has no --quiet)
    (cd "$t" && grep " tso-arm-$v-linux-arm64.tar.gz\$" SHA256SUMS | sha256sum -c - >/dev/null) ||
        die "the package does not match its checksum"
fi

mkdir -p "$dest"
rm -rf "$dest/$v.new"
mkdir -p "$dest/$v.new"
tar -xzf "$pkg" -C "$dest/$v.new" || die "$pkg is not a release package"
new=$dest/$v.new/tso-arm-$v
[ -x "$new/bin/tso-arm" ] && [ -x "$new/fex/prebuilt/bin/FEX" ] || die "$pkg holds no tso-arm with its prebuilt FEX"
# whether the prebuilt FEX finds the libraries it was linked against, in versions new enough: glibc's dynamic loader
# lists what it lacks
l=$("$LD" --list "$new/fex/prebuilt/bin/FEX" 2>&1 | grep 'not found' || true)
if [ -n "$l" ]; then
    rm -rf "$dest/$v.new"
    rmdir "$dest" 2>/dev/null || true
    libs=$(printf '%s\n' "$l" | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p')
    [ -z "$libs" ] || missing "the prebuilt FEX needs" $libs
    # (a version not found: "FEX: /lib64/libstdc++.so.6: version `GLIBCXX_3.4.30' not found (required by FEX)")
    die "the libraries of $distro are older than the prebuilt FEX needs:
$(printf '%s\n' "$l" | sed 's/^[[:space:]]*/  /')"
fi
old=$(readlink "$dest/current" 2>/dev/null || true)
rm -rf "$dest/$v"
mv "$new" "$dest/$v"
rmdir "$dest/$v.new"
ln -sfn "$v" "$dest/current.new"
# in one step where mv can replace a link (GNU's and BusyBox's mv -T)
mv -T "$dest/current.new" "$dest/current" 2>/dev/null || {
    rm -f "$dest/current.new"
    ln -sfn "$v" "$dest/current"
}
mkdir -p "$bindir"
ln -sfn "$dest/current/bin/tso-arm" "$bindir/tso-arm"
# the version before stays until the next update, the older ones go
for d in "$dest"/*/; do
    d=${d%/}
    n=$(basename "$d")
    case $n in "$v" | "$old" | current | rootfs) continue ;; esac
    [ -f "$d/VERSION" ] && rm -rf "$d"
done
if [ -n "$old" ] && [ "$old" != "$v" ]; then
    say "updated from $old to $v ($dest/$v)"
else
    say "installed $v into $dest/$v"
fi

# (a container sees binfmt_misc read-only, if at all)
if [ "$(id -u)" = 0 ] && [ "${TSO_ARM_BINFMT:-1}" != 0 ] && [ -f /proc/sys/fs/binfmt_misc/status ]; then
    "$dest/current/bin/tso-arm" binfmt register ||
        say "x86 programs started directly do not run through tso-arm (binfmt_misc could not be written); 'tso-arm run PROGRAM' does"
fi
case ":$PATH:" in
*":$bindir:"*) ;;
*) say "add $bindir to PATH to call 'tso-arm' from anywhere (or log in again: most distributions add ~/.local/bin once it exists)" ;;
esac
"$dest/current/bin/tso-arm" check | tail -n 1
sh "$dest/current/tools/pages_hint.sh" || true
say "next: 'tso-arm rootfs' once for dynamically linked programs, then 'tso-arm run PROGRAM'"

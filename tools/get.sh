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
set -e
REPO_URL=https://github.com/DustinHab/tso-arm

say() { echo "tso-arm: $*"; }
die() {
    echo "tso-arm: $*" >&2
    exit 1
}

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] ||
    die "tso-arm runs on 64-bit Arm Linux; this is $(uname -s) on $(uname -m)"
# the prebuilt FEX needs glibc 2.35 (Ubuntu 22.04, Debian 12) or newer
g=$(ldd --version 2>/dev/null | sed -n '1s/.* \([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
if [ -n "$g" ] && [ "${g%%.*}" -eq 2 ] && [ "${g#*.}" -lt 35 ]; then
    die "this system has glibc $g; the prebuilt FEX needs 2.35 or newer. On older systems FEX is built from source:
  git clone $REPO_URL && tso-arm/bin/tso-arm install --source"
fi

if [ "$(id -u)" = 0 ]; then
    dest=${TSO_ARM_DEST:-/opt/tso-arm}
    bindir=/usr/local/bin
else
    dest=${TSO_ARM_DEST:-${XDG_DATA_HOME:-$HOME/.local/share}/tso-arm}
    bindir=$HOME/.local/bin
fi

if command -v curl >/dev/null; then
    get() { curl -fsSL --retry 2 -o "$2" "$1"; }
    getout() { curl -fsSL --retry 2 "$1"; }
elif command -v wget >/dev/null; then
    get() { wget -q -O "$2" "$1"; }
    getout() { wget -q -O - "$1"; }
else
    die "needs curl or wget"
fi

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
if [ -n "$TSO_ARM_TARBALL" ]; then
    pkg=$TSO_ARM_TARBALL
    v=$(basename "$pkg" | sed -n 's/^tso-arm-\([0-9][0-9.]*\)-linux-arm64\.tar\.gz$/\1/p')
    [ -n "$v" ] || die "$pkg is not named like a release package (tso-arm-VERSION-linux-arm64.tar.gz)"
else
    v=${TSO_ARM_VERSION:-}
    if [ -z "$v" ]; then
        v=$(getout "https://api.github.com/repos/DustinHab/tso-arm/releases/latest" |
            sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)
        [ -n "$v" ] || die "could not find the newest release on GitHub (no connection?)"
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
    get "$REPO_URL/releases/download/v$v/tso-arm-$v-linux-arm64.tar.gz" "$pkg" ||
        die "no release package for $v"
    get "$REPO_URL/releases/download/v$v/SHA256SUMS" "$t/SHA256SUMS" || die "no checksums for $v"
    (cd "$t" && grep " tso-arm-$v-linux-arm64.tar.gz\$" SHA256SUMS | sha256sum -c --quiet -) ||
        die "the package does not match its checksum"
fi

mkdir -p "$dest"
rm -rf "$dest/$v.new"
mkdir -p "$dest/$v.new"
tar -xzf "$pkg" -C "$dest/$v.new" || die "$pkg is not a release package"
[ -x "$dest/$v.new/tso-arm-$v/bin/tso-arm" ] && [ -x "$dest/$v.new/tso-arm-$v/fex/prebuilt/bin/FEX" ] ||
    die "$pkg holds no tso-arm with its prebuilt FEX"
old=$(readlink "$dest/current" 2>/dev/null || true)
rm -rf "$dest/$v"
mv "$dest/$v.new/tso-arm-$v" "$dest/$v"
rmdir "$dest/$v.new"
ln -sfn "$v" "$dest/current.new"
mv -T "$dest/current.new" "$dest/current"
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

if [ "$(id -u)" = 0 ] && [ "${TSO_ARM_BINFMT:-1}" != 0 ] && [ -f /proc/sys/fs/binfmt_misc/status ]; then
    "$dest/current/bin/tso-arm" binfmt register
fi
case ":$PATH:" in
*":$bindir:"*) ;;
*) say "add $bindir to PATH to call 'tso-arm' from anywhere (or log in again: most distributions add ~/.local/bin once it exists)" ;;
esac
"$dest/current/bin/tso-arm" check | tail -n 1
sh "$dest/current/tools/pages_hint.sh" || true
say "next: 'tso-arm rootfs' once for dynamically linked programs, then 'tso-arm run PROGRAM'"

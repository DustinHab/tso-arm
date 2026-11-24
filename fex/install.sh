#!/bin/sh
# Installs FEX with the tso-arm patches for the current user (what `tso-arm install` runs).
#   fex/install.sh              the prebuilt FEX of this release: from the release package this checkout came in, or
#                               fetched from GitHub for this version; built from source when there is none for
#                               exactly these patches
#   fex/install.sh --source     built from source, tuned for this machine's core
#   fex/install.sh --generic    built from source, for any Armv8.0 core (how the prebuilt one is built)
#   TSO_ARM_PACKAGE: a FEX package downloaded beforehand (tso-arm-fex-VERSION-linux-arm64.tar.gz) to install
#   TSO_ARM_PREFIX (default ~/.local/opt/tso-arm), TSO_ARM_SRC (default ~/.local/src/tso-arm/FEX): the FEX checkout
#   TSO_ARM_FEX_REF: another FEX commit or branch than the one the patches were made on (origin/main: FEX's newest)
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
SRC=${TSO_ARM_SRC:-$HOME/.local/src/tso-arm/FEX}
PREFIX=${TSO_ARM_PREFIX:-$HOME/.local/opt/tso-arm}
VERSION=$(cat "$R/VERSION")
RELEASE=https://github.com/DustinHab/tso-arm/releases/download/v$VERSION
PACKAGE=tso-arm-fex-$VERSION-linux-arm64.tar.gz
BASE=be66e03 # the FEX commit the patches apply to
if [ -n "$TSO_ARM_FEX_REF" ]; then
    BASE=$TSO_ARM_FEX_REF
fi

say() { echo "tso-arm install: $*"; }
die() {
    echo "tso-arm install: $*" >&2
    exit 1
}

case ${1:-} in
"") how=package ;;
--source) how=source tune="-DTUNE_CPU=native" ;;
--generic) how=source tune="-DTUNE_CPU=none -DTUNE_ARCH=armv8-a" ;;
*) die "unknown option $1 (--source, --generic)" ;;
esac
[ "$(uname -m)" = aarch64 ] || die "tso-arm runs on 64-bit Arm Linux; this is $(uname -s) on $(uname -m)"

# which patches a FEX build carries: a hash over the patch files, so that a prebuilt FEX is used only with the
# scripts it was built for
patches() { cat "$R"/fex/patches/*tso-arm-stage*.patch | sha256sum | cut -c1-16; }

# the command itself, on the user's PATH where the distribution puts ~/.local/bin
finish() {
    say "FEX installed to $PREFIX ($1)"
    sh "$R/tools/pages_hint.sh" | sed 's/^/tso-arm install: /' >&2 || true
    mkdir -p "$HOME/.local/bin"
    ln -sf "$R/bin/tso-arm" "$HOME/.local/bin/tso-arm"
    case ":$PATH:" in
    *":$HOME/.local/bin:"*) say "'tso-arm' is ready; 'tso-arm check' tells whether this machine can run it" ;;
    *) say "add ~/.local/bin to PATH to call 'tso-arm' from anywhere ($R/bin/tso-arm works as well)" ;;
    esac
    exit 0
}

# a prebuilt FEX, a directory with bin/, share/ and BUILD; only if it was built from these patches
from_dir() {
    [ -x "$1/bin/FEX" ] && [ -f "$1/BUILD" ] || return 1
    if [ "$(sed -n 's/^patches //p' "$1/BUILD")" != "$(patches)" ]; then
        say "the prebuilt FEX in $1 was built from other patches than these"
        return 1
    fi
    rm -rf "$PREFIX.new"
    mkdir -p "$PREFIX.new"
    cp -R "$1/bin" "$1/share" "$1/BUILD" "$PREFIX.new/"
    rm -rf "$PREFIX"
    mv "$PREFIX.new" "$PREFIX"
}

from_tarball() {
    t=$(mktemp -d)
    trap 'rm -rf "$t"' EXIT
    tar -xzf "$1" -C "$t" || die "$1 is not a FEX package"
    from_dir "$t"/tso-arm-fex-* || return 1
}

if [ $how = package ]; then
    if [ -n "$TSO_ARM_PACKAGE" ]; then
        from_tarball "$TSO_ARM_PACKAGE" || die "$TSO_ARM_PACKAGE does not fit these scripts; 'tso-arm install --source' builds FEX"
        finish "prebuilt, from $TSO_ARM_PACKAGE"
    fi
    if [ -d "$R/fex/prebuilt" ] && from_dir "$R/fex/prebuilt"; then
        finish "prebuilt, from the release package"
    fi
    if command -v curl >/dev/null; then
        get() { curl -fsSL --retry 2 -o "$2" "$1"; }
    elif command -v wget >/dev/null; then
        get() { wget -q -O "$2" "$1"; }
    else
        get() { return 1; }
    fi
    d=$(mktemp -d)
    say "fetching the prebuilt FEX of tso-arm $VERSION"
    if get "$RELEASE/$PACKAGE" "$d/$PACKAGE" && get "$RELEASE/SHA256SUMS" "$d/SHA256SUMS"; then
        (cd "$d" && grep " $PACKAGE\$" SHA256SUMS | sha256sum -c --quiet -) || die "$PACKAGE does not match its checksum"
        if from_tarball "$d/$PACKAGE"; then
            rm -rf "$d"
            finish "prebuilt, tso-arm $VERSION"
        fi
    fi
    rm -rf "$d"
    say "no prebuilt FEX for exactly these patches (or no connection to GitHub); building it from source"
    tune="-DTUNE_CPU=native"
fi

missing=""
for t in git cmake ninja clang clang++ ld.lld python3; do
    command -v $t >/dev/null || missing="$missing $t"
done
if [ -n "$missing" ]; then
    die "missing:$missing
  on Debian or Ubuntu: sudo apt install git cmake ninja-build clang lld python3"
fi

if [ ! -d "$SRC/.git" ]; then
    say "fetching FEX into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone -q https://github.com/FEX-Emu/FEX.git "$SRC"
fi
cd "$SRC"
if [ -n "$TSO_ARM_FEX_REF" ] || ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
    git fetch -q origin
fi
commit=$(git log -1 --format='%h (%cs)' "$BASE")
say "FEX $commit with $(ls "$R"/fex/patches/*tso-arm-stage*.patch | wc -l) tso-arm patches"
git checkout -q -f --detach "$BASE"
git clean -fdq -e 'Build-*'
git submodule update -q --init --recursive
for p in "$R"/fex/patches/*tso-arm-stage*.patch; do
    git apply --whitespace=nowarn "$p" || die "$(basename "$p") does not apply to FEX $BASE"
done

B="$SRC/Build-tso-arm"
case $tune in *none*) B="$B-generic" ;; esac
mkdir -p "$B"
cd "$B"
CC=clang CXX=clang++ cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DUSE_LINKER=lld -DENABLE_LTO=False -DBUILD_TESTING=False -DENABLE_ASSERTIONS=False \
    -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False $tune >"$B/cmake.log" 2>&1 || {
    tail -n 20 "$B/cmake.log" >&2
    exit 1
}
say "building (this takes a while; log in $B/build.log)"
nice -n 10 ninja >"$B/build.log" 2>&1 || {
    tail -n 20 "$B/build.log" >&2
    exit 1
}
ninja install >/dev/null
case $tune in
*none*) built="from source, for any Armv8.0 core" ;;
*) built="from source, for this core" ;;
esac
printf 'patches %s\nfex %s\nbuilt %s\n' "$(patches)" "$commit" "$built" >"$PREFIX/BUILD"
finish "built $built"

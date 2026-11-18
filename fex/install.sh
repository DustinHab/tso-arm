#!/bin/sh
# Builds FEX with the tso-arm patches and installs it for the current user (what `tso-arm install` runs).
#   fex/install.sh [--generic]
#   --generic: for any Armv8.0 core instead of the build machine's own (slower, runs everywhere)
#   TSO_ARM_SRC (default ~/.local/src/tso-arm/FEX): the FEX checkout; TSO_ARM_PREFIX (default ~/.local/opt/tso-arm)
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
SRC=${TSO_ARM_SRC:-$HOME/.local/src/tso-arm/FEX}
PREFIX=${TSO_ARM_PREFIX:-$HOME/.local/opt/tso-arm}
BASE=be66e03 # the FEX commit the patches apply to
tune="-DTUNE_CPU=native"
if [ "$1" = --generic ]; then
    tune="-DTUNE_CPU=none -DTUNE_ARCH=armv8-a"
fi

missing=""
for t in git cmake ninja clang clang++ ld.lld python3; do
    command -v $t >/dev/null || missing="$missing $t"
done
if [ -n "$missing" ]; then
    echo "tso-arm install: missing:$missing" >&2
    echo "  on Debian or Ubuntu: sudo apt install git cmake ninja-build clang lld python3" >&2
    exit 1
fi

if [ ! -d "$SRC/.git" ]; then
    echo "tso-arm install: fetching FEX into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone -q https://github.com/FEX-Emu/FEX.git "$SRC"
fi
cd "$SRC"
if ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
    git fetch -q origin
fi
echo "tso-arm install: FEX $BASE with $(ls "$R"/fex/patches/*tso-arm-stage*.patch | wc -l) tso-arm patches"
git checkout -q -f --detach "$BASE"
git clean -fdq -e 'Build-*'
git submodule update -q --init --recursive
for p in "$R"/fex/patches/*tso-arm-stage*.patch; do
    git apply --whitespace=nowarn "$p"
done

B="$SRC/Build-tso-arm"
if [ "$1" = --generic ]; then
    B="$B-generic"
fi
mkdir -p "$B"
cd "$B"
CC=clang CXX=clang++ cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DUSE_LINKER=lld -DENABLE_LTO=False -DBUILD_TESTING=False -DENABLE_ASSERTIONS=False \
    -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False $tune >"$B/cmake.log" 2>&1 || {
    tail -n 20 "$B/cmake.log" >&2
    exit 1
}
echo "tso-arm install: building (this takes a while; log in $B/build.log)"
nice -n 10 ninja >"$B/build.log" 2>&1 || { tail -n 20 "$B/build.log" >&2; exit 1; }
ninja install >/dev/null
echo "tso-arm install: FEX installed to $PREFIX"

#!/bin/sh
# Release packages from a FEX built with the tso-arm patches for any Armv8.0 core (what the release workflow runs):
#   tools/package.sh PREFIX OUT [FEX_SOURCE]
#   OUT/tso-arm-fex-VERSION-linux-arm64.tar.gz   FEX alone, what 'tso-arm install' fetches
#   OUT/tso-arm-VERSION-linux-arm64.tar.gz       the files of this commit with that FEX in fex/prebuilt
#   OUT/SHA256SUMS
# FEX_SOURCE (default ~/.local/src/tso-arm/FEX): the checkout it was built from, for the licenses that go with it
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
P=$1
O=$2
S=${3:-$HOME/.local/src/tso-arm/FEX}
V=$(cat "$R/VERSION")
die() {
    echo "package: $*" >&2
    exit 1
}
[ -n "$O" ] || die "usage: tools/package.sh PREFIX OUT [FEX_SOURCE]"
[ -x "$P/bin/FEX" ] && [ -f "$P/BUILD" ] || die "no FEX with a BUILD file in $P"
grep -q '^built .*any Armv8.0' "$P/BUILD" || die "the FEX in $P is not built for any Armv8.0 core (--generic)"
[ -f "$S/LICENSE" ] || die "no FEX checkout in $S"
mkdir -p "$O"
O=$(cd "$O" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

F=$t/tso-arm-fex-$V
mkdir -p "$F/licenses"
cp -R "$P/bin" "$P/share" "$F/"
# the thunks' host libraries (FEX's own libFEXCore.so is linked into its programs)
if [ -d "$P/lib/fex-emu" ]; then
    mkdir -p "$F/lib"
    cp -R "$P/lib/fex-emu" "$F/lib/"
fi
th=""
grep -q '^built .*with thunks' "$P/BUILD" && th=", with thunks"
sed "s/^built .*/built prebuilt, tso-arm $V, for any Armv8.0 core$th/" "$P/BUILD" >"$F/BUILD"
# FEX's license and those of the libraries built into it
cp "$S/LICENSE" "$F/licenses/FEX"
for d in "$S"/External/*/; do
    for l in "$d"LICENSE* "$d"COPYING* "$d"LICENCE*; do
        [ -f "$l" ] && cp "$l" "$F/licenses/$(basename "$d")-$(basename "$l")"
    done
done
cp "$R/LICENSE" "$F/licenses/tso-arm"

pack() { tar -C "$t" --owner=0 --group=0 --numeric-owner -czf "$O/$1.tar.gz" "$2"; }
pack "tso-arm-fex-$V-linux-arm64" "tso-arm-fex-$V"
git -C "$R" archive --format=tar --prefix="tso-arm-$V/" HEAD | tar -x -C "$t"
cp -R "$F" "$t/tso-arm-$V/fex/prebuilt"
pack "tso-arm-$V-linux-arm64" "tso-arm-$V"
cd "$O"
sha256sum tso-arm-*"$V"-linux-arm64.tar.gz >SHA256SUMS
cat SHA256SUMS
ls -l "$O"

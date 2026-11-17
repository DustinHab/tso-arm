#!/bin/sh
# Builds the workloads natively for AArch64 on the test machine, from the same official sources, versions and
# compiler options as the x86-64 builds (study/build_static.sh). Reference for the efficiency measurement.
# Output: build/arm64/{zstd,xz,pigz}
#   bench/build_native.sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
S=$HOME/native-src
O=$R/build/arm64
mkdir -p $S $O
cd $S
J=$(nproc)
CF="-O2 -fno-pie -fno-stack-protector"
LF="-static -no-pie"

fetch() { [ -f "$2" ] || curl -sSLf -o "$2" "$1"; }

# zstd
fetch https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz zstd.tar.gz
[ -d zstd-1.5.7 ] || tar xzf zstd.tar.gz
make -s -C zstd-1.5.7/programs -j$J zstd CFLAGS="$CF" LDFLAGS="$LF" >/dev/null
cp zstd-1.5.7/programs/zstd $O/zstd

# xz
fetch https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz xz.tar.gz
[ -d xz-5.8.4 ] || tar xzf xz.tar.gz
if [ ! -f xz-5.8.4/Makefile ]; then
    (cd xz-5.8.4 && ./configure -q --disable-shared --enable-static --disable-nls CFLAGS="$CF" >/dev/null)
fi
if ! file xz-5.8.4/src/xz/xz 2>/dev/null | grep -q 'statically linked'; then
    rm -f xz-5.8.4/src/xz/xz
    make -s -C xz-5.8.4 -j$J LDFLAGS="-all-static -no-pie" >/dev/null
fi
cp xz-5.8.4/src/xz/xz $O/xz

# zlib + pigz
fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib.tar.gz
[ -d zlib-1.3.1 ] || tar xzf zlib.tar.gz
(cd zlib-1.3.1 && [ -f libz.a ] || { CFLAGS="$CF" ./configure --static >/dev/null && make -s -j$J libz.a >/dev/null; })
fetch https://github.com/madler/pigz/archive/refs/tags/v2.8.tar.gz pigz.tar.gz
[ -d pigz-2.8 ] || tar xzf pigz.tar.gz
make -s -C pigz-2.8 -j$J pigz CFLAGS="$CF -I$S/zlib-1.3.1" LDFLAGS="$LF -L$S/zlib-1.3.1" >/dev/null
cp pigz-2.8/pigz $O/pigz

cd $O
for f in zstd xz pigz; do printf '%-5s ' $f; file -b $f | cut -c1-80; done

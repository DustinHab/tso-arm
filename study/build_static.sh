#!/bin/sh
# Builds static, non-PIE x86-64 workload binaries from official sources, so that the same file runs under the
# study client (WSL) and under FEX on the test machine, at the same addresses.
# Output: build/x86/{zstd,xz,pigz,7zz}
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/build_static.sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
S=$HOME/study/src
O=$R/build/x86
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
# libtool drops -static; -all-static is its spelling
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

# 7-Zip
fetch https://www.7-zip.org/a/7z2600-src.tar.xz 7z-src.tar.xz
if [ ! -d 7z-src ]; then mkdir 7z-src && tar xJf 7z-src.tar.xz -C 7z-src; fi
(cd 7z-src/CPP/7zip/Bundles/Alone2 &&
    make -s -j$J -f makefile.gcc LDFLAGS_STATIC_2="$LF" CFLAGS_BASE_LIST="-c -fno-pie" >/dev/null)
cp 7z-src/CPP/7zip/Bundles/Alone2/_o/7zz $O/7zz

cd $O
for f in *; do printf '%-6s ' $f; file -b $f | cut -c1-90; done

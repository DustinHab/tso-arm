#!/bin/sh
# Position-independent x86-64 builds of the workloads, as distributions build programs: pigz, xz and zstd as PIE linked
# dynamically against the C library (build/x86pie), and pigz as static-pie (build/x86spie). The same sources and
# options as study/build_static.sh otherwise; separate source copies, since every object has to be built with -fPIE.
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/build_pie.sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
S=$HOME/study/src
P=$HOME/study/src-pie
O=$R/build/x86pie
OS=$R/build/x86spie
mkdir -p $P $O $OS
J=$(nproc)
CF="-O2 -fPIE -fno-stack-protector"
for d in zstd-1.5.7 xz-5.8.4 zlib-1.3.1 pigz-2.8; do
    [ -d $P/$d ] || cp -a $S/$d $P/$d
done
cd $P

make -s -C zstd-1.5.7/programs clean >/dev/null
make -s -C zstd-1.5.7/programs -j$J zstd CFLAGS="$CF" LDFLAGS="-pie" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null
cp zstd-1.5.7/programs/zstd $O/zstd

(cd xz-5.8.4 && make -s distclean >/dev/null 2>&1 || true)
(cd xz-5.8.4 && ./configure -q --disable-shared --enable-static --disable-nls CFLAGS="$CF" >/dev/null)
make -s -C xz-5.8.4 -j$J LDFLAGS="-pie" >/dev/null
cp xz-5.8.4/src/xz/xz $O/xz

(cd zlib-1.3.1 && make -s distclean >/dev/null 2>&1 || true)
(cd zlib-1.3.1 && CFLAGS="$CF" ./configure --static >/dev/null && make -s -j$J libz.a >/dev/null)
make -s -C pigz-2.8 clean >/dev/null 2>&1 || true
make -s -C pigz-2.8 -j$J pigz CFLAGS="$CF -I$P/zlib-1.3.1" LDFLAGS="-pie -L$P/zlib-1.3.1" >/dev/null
cp pigz-2.8/pigz $O/pigz
rm -f pigz-2.8/pigz
make -s -C pigz-2.8 -j$J pigz CFLAGS="$CF -I$P/zlib-1.3.1" LDFLAGS="-static-pie -L$P/zlib-1.3.1" >/dev/null
cp pigz-2.8/pigz $OS/pigz

file $O/* $OS/* | sed 's/, BuildID[^,]*//' | cut -c1-140

#!/bin/sh
# Builds dynamically linked x86-64 variants of the workloads and the litmus test for Box64, which refuses static
# binaries: the same sources and options as study/build_static.sh, zlib, liblzma and libzstd linked in, only the C
# library dynamic (Box64 runs it as native Arm code; for these programs a few percent of their time at most).
# Output: build/x86dyn/{zstd,xz,pigz,mp}
#   wsl.exe -d Ubuntu -- sh /mnt/c/Users/dusti/tso-arm/study/build_dynamic.sh
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
S=$HOME/study/src
O=$R/build/x86dyn
mkdir -p $O
cd $S
J=$(nproc)
CF="-O2 -fno-pie -fno-stack-protector"
LF="-no-pie"

rm -f zstd-1.5.7/programs/zstd
# without the gzip and xz formats (zlib, liblzma): Box64 would run those libraries natively
make -s -C zstd-1.5.7/programs -j$J zstd CFLAGS="$CF" LDFLAGS="$LF" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null
cp zstd-1.5.7/programs/zstd $O/zstd
rm -f zstd-1.5.7/programs/zstd

rm -f xz-5.8.4/src/xz/xz
make -s -C xz-5.8.4 -j$J LDFLAGS="$LF" >/dev/null
cp xz-5.8.4/src/xz/xz $O/xz
rm -f xz-5.8.4/src/xz/xz

rm -f pigz-2.8/pigz
make -s -C pigz-2.8 -j$J pigz CFLAGS="$CF -I$S/zlib-1.3.1" LDFLAGS="$LF -L$S/zlib-1.3.1" >/dev/null
cp pigz-2.8/pigz $O/pigz
rm -f pigz-2.8/pigz

gcc -O2 -pthread -o $O/mp $R/litmus/mp.c
file $O/* | sed 's/, BuildID[^,]*//' | cut -c1-150
for b in zstd xz pigz; do printf '%s needs: %s\n' $b "$(objdump -p $O/$b | awk '/NEEDED/ { printf "%s ", $2 }')"; done

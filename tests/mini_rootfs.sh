#!/bin/sh
# On an x86-64 Linux machine: a minimal x86-64 root file system (the dynamic loader, libc, libm, libpthread) as
# build/rootfs-x86.tar.gz, for testing dynamically linked programs under FEX without fetching a full image.
#   tests/mini_rootfs.sh
set -e
cd "$(dirname "$0")/.."
R=$(mktemp -d)
mkdir -p $R/lib64 $R/lib/x86_64-linux-gnu $R/etc
cp -L /lib64/ld-linux-x86-64.so.2 $R/lib64/
for l in libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2; do
    [ -e /lib/x86_64-linux-gnu/$l ] && cp -L /lib/x86_64-linux-gnu/$l $R/lib/x86_64-linux-gnu/
done
ln -s lib $R/usr 2>/dev/null || true
tar -czf build/rootfs-x86.tar.gz -C $R .
rm -rf $R
ls -la build/rootfs-x86.tar.gz
ldd --version | head -n 1

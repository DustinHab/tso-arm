#!/bin/sh
# Test machine: the tso-arm FEX build for any Armv8.0 core (no tuning for the Cortex-A76 of the test machine, which
# the normal build has: -mcpu=cortex-a76), from the tree fex/build_views.sh checked out, to ~/opt/fex-generic (build
# directory ~/src/FEX/Build-generic). For running under an emulated older core. Log: out/build_generic.log
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
exec >$R/out/build_generic.log 2>&1
cd ~/src/FEX
git log --oneline -1
mkdir -p Build-generic && cd Build-generic
if [ ! -f build.ninja ]; then
    CC=clang CXX=clang++ cmake -G Ninja .. \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/opt/fex-generic \
        -DUSE_LINKER=lld -DENABLE_LTO=False -DBUILD_TESTING=False -DENABLE_ASSERTIONS=False \
        -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False -DTUNE_CPU=none -DTUNE_ARCH=armv8-a >/dev/null
fi
nice -n 10 ninja -j4
ninja install >/dev/null
grep -o '\-mcpu=[a-z0-9.+-]*\|-march=[a-z0-9.+-]*' build.ninja | sort | uniq -c
echo "=== done $(date '+%T')"

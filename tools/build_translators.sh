#!/bin/sh
# Clones and builds FEX and Box64 under ~/src on the test machine. Log: ~/tso-arm/out/build_translators.log
#   tools/build_translators.sh [fex|box64|all]
set -e
what=${1:-all}
mkdir -p ~/src ~/tso-arm/out
log=~/tso-arm/out/build_translators.log
exec >>"$log" 2>&1
echo "=== $(date '+%F %T') start $what"

if [ "$what" = fex ] || [ "$what" = all ]; then
    cd ~/src
    [ -d FEX ] || git clone --recurse-submodules --depth 1 --shallow-submodules https://github.com/FEX-Emu/FEX.git
    cd FEX
    git log -1 --format='FEX %h %cd %s' --date=short
    mkdir -p Build && cd Build
    CC=clang CXX=clang++ cmake -G Ninja .. \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/opt/fex \
        -DUSE_LINKER=lld -DENABLE_LTO=False -DBUILD_TESTING=False -DENABLE_ASSERTIONS=False \
        -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False
    nice -n 10 ninja -j4
    ninja install
    echo "=== $(date '+%F %T') FEX done"
fi

if [ "$what" = box64 ] || [ "$what" = all ]; then
    cd ~/src
    [ -d box64 ] || git clone --depth 1 https://github.com/ptitSeb/box64.git
    cd box64
    git log -1 --format='Box64 %h %cd %s' --date=short
    mkdir -p build && cd build
    cmake .. -DRPI5ARM64=1 -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$HOME/opt/box64 -DNOGIT=0
    nice -n 10 make -j4
    echo "=== $(date '+%F %T') Box64 done"
fi
echo "=== $(date '+%F %T') end"

#!/bin/sh
# Applies the tso-arm view patches (fex/patches/*tso-arm-stage*.patch) to FEX be66e03 on branch tso-views and
# installs the result to ~/opt/fex-views (build directory ~/src/FEX/Build-views). Log: out/build_views.log
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
exec >$R/out/build_views.log 2>&1
cd ~/src/FEX
git config user.name DustinHab
git config user.email 142697073+DustinHab@users.noreply.github.com
git checkout -q -f -B tso-views be66e03
git am -q $R/fex/patches/*tso-arm-stage*.patch
git log --oneline -3
mkdir -p Build-views && cd Build-views
if [ ! -f build.ninja ]; then
    CC=clang CXX=clang++ cmake -G Ninja .. \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/opt/fex-views \
        -DUSE_LINKER=lld -DENABLE_LTO=False -DBUILD_TESTING=False -DENABLE_ASSERTIONS=False \
        -DBUILD_FEXCONFIG=False -DBUILD_THUNKS=False >/dev/null
fi
nice -n 10 ninja -j4
ninja install >/dev/null
echo "=== done $(date '+%T')"

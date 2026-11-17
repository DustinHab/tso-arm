#!/bin/sh
# Applies fex/oracle_patch.py on a branch of ~/src/FEX and installs the result to ~/opt/fex-oracle.
# The unpatched build stays in ~/opt/fex. Patch export: fex/patches/
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
cd ~/src/FEX
git config user.name DustinHab
git config user.email 142697073+DustinHab@users.noreply.github.com
git checkout -q -B tso-oracle
python3 $R/fex/oracle_patch.py
git commit -q -am "tso-arm: per-instruction plain list (oracle experiment)" || true
mkdir -p $R/fex/patches
git format-patch -q -o $R/fex/patches main..tso-oracle 2>/dev/null || git format-patch -q -o $R/fex/patches HEAD~1
cd Build
cmake -DCMAKE_INSTALL_PREFIX=$HOME/opt/fex-oracle . >/dev/null
nice -n 10 ninja -j4 2>&1 | tail -n 3
ninja install >/dev/null
ls -la $HOME/opt/fex-oracle/bin/FEX

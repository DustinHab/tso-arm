#!/bin/sh
# In WSL: folds the working tree of ~/src/FEX (branch tso-views) into one commit per stage and exports the patches
# to fex/patches/. Usage: fex/export_views.sh "commit message"
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
BASE=$(sed -n 's/^BASE=\([0-9a-f]*\).*/\1/p' "$R/fex/install.sh")
cd ~/src/FEX
git add -A
if [ -n "$(git diff --cached --name-only)" ]; then
    git commit -q --amend --no-edit
fi
rm -f $R/fex/patches/*tso-arm-stage*.patch
# full object names in the index lines: abbreviated ones grow with the objects the checkout has (a fetch), and the
# patch hash tso-arm checks a FEX build against would change with them
git format-patch -q --full-index -o $R/fex/patches "$BASE..tso-views"
ls $R/fex/patches

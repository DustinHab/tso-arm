#!/bin/sh
# In WSL: folds the working tree of ~/src/FEX (branch tso-views) into one commit per stage and exports the patches
# to fex/patches/. Usage: fex/export_views.sh "commit message"
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
cd ~/src/FEX
git add -A
if [ -n "$(git diff --cached --name-only)" ]; then
    git commit -q --amend --no-edit
fi
rm -f $R/fex/patches/*tso-arm-stage*.patch
git format-patch -q -o $R/fex/patches be66e03..tso-views
ls $R/fex/patches

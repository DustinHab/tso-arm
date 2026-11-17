#!/bin/sh
# Shows the generated C++ struct of an IR op (default LoadMem) from the FEX build tree.
op=${1:-LoadMem}
f=~/src/FEX/Build/include/FEXCore/IR/IRDefines.inc
grep -n -A30 "struct IROp_$op " "$f" | head -45

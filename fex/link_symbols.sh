#!/bin/sh
# Test machine: FEX's interpreter linked once more from the views build tree without --strip-all (same code and
# addresses, with a symbol table), to ~/opt/fex-views/bin/FEX-sym, for perf.
#   fex/link_symbols.sh
set -e
cd ~/src/FEX/Build-views
cmd=$(ninja -t commands Bin/FEX | tail -n 1)
cmd=$(echo "$cmd" | sed 's/-Xlinker --strip-all//g; s/-Wl,--strip-all//g; s/,--strip-all//g; s# -o Bin/FEX # -o Bin/FEX-sym #')
sh -c "$cmd"
cp Bin/FEX-sym ~/opt/fex-views/bin/FEX-sym
file ~/opt/fex-views/bin/FEX-sym | grep -o 'not stripped\|, stripped'
cmp -s Bin/FEX Bin/FEX-sym && echo identical || echo "differs (symbol table)"

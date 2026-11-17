#!/bin/sh
# Quick correctness matrix for the views build: output and exit status per configuration.
cd "$(dirname "$0")/.."
F=$HOME/opt/fex-views/bin/FEX
run() {
    label=$1
    shift
    out=$(env "$@" 2>/tmp/vm.err | tr '\0' '@' | tail -c 120)
    echo "$label: exit $? | $out"
}
BASE="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1"
run "fields stage1      " $BASE TSO_VIEWS_STAGE1=1 $F build/fields-x86 1000
run "fields protocol    " $BASE $F build/fields-x86 1000
run "mp stage1          " $BASE TSO_VIEWS_STAGE1=1 $F build/mp-x86 mp 20000
run "mp protocol        " $BASE $F build/mp-x86 mp 20000
run "mp plain-off       " TSO_VIEWS=1 FEX_TSOENABLED=0 $F build/mp-x86 mp 20000
run "threads protocol   " $BASE $F build/threads-x86 12
# native x86: shared 1 checksum d6b6b3bdc8d2a73a, failed creates 0
run "sharedstack proto. " $BASE $F build/sharedstack-x86 2000

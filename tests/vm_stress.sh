#!/bin/sh
# Runs inside the test VM (GUEST=vm_stress.sh tests/vm_run.sh MODEL): the threads test beyond the view slots many
# times, with and without SVE, and the stderr of failing runs.
exec >/dev/ttyAMA0 2>&1
cd /root/t
r() { echo "TSOTEST $*"; }
F=/root/t/fex/bin/FEX
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
for extra in "" "FEX_HOSTFEATURES=disablesve"; do
    fail=0
    for i in $(seq 40); do
        out=$(env $P $extra timeout 300 $F ./threads-x86 20 2>/tmp/err | tail -n 1)
        rc=$?
        if [ $rc -ne 0 ] || ! echo "$out" | grep -q 'wrong 0'; then
            fail=$((fail + 1))
            r "fail ${extra:-with SVE} #$i: exit $rc | $out | $(grep -v '^$' /tmp/err | tail -n 4 | tr '\n' ' ' | cut -c1-300)"
        fi
    done
    r "${extra:-with SVE}: $fail of 40 failed"
done
r "done"
poweroff

#!/bin/sh
# Runs inside the test VM instead of tests/vm_guest.sh (GUEST=vm_diag.sh tests/vm_run.sh MODEL): narrows down a
# failure of the threads test beyond the view slots (with and without SVE, with and without the views, the
# protocol's log) and runs upstream FEX (fex-up) next to the tso-arm build.
exec >/dev/ttyAMA0 2>&1
cd /root/t
r() { echo "TSOTEST $*"; }
F=/root/t/fex/bin/FEX
U=/root/t/fex-up/bin/FEX
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
T="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1"
r "core: $(grep -m1 'CPU part' /proc/cpuinfo | cut -d: -f2)"
t() {
    label=$1
    shift
    timeout 1800 "$@" >/tmp/out 2>/tmp/err
    rc=$?
    r "$label: exit $rc | $(tail -n 1 /tmp/out) | $(grep -v '^$' /tmp/err | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
}
for i in 1 2 3; do t "threads 20, protocol #$i" env $P $F ./threads-x86 20; done
for i in 1 2 3; do t "threads 20, protocol, no SVE #$i" env $P FEX_HOSTFEATURES=disablesve $F ./threads-x86 20; done
for i in 1 2; do t "threads 20, FEX full TSO (no views) #$i" env $T $F ./threads-x86 20; done
for i in 1 2; do t "threads 15, protocol #$i" env $P $F ./threads-x86 15; done
t "threads 8, upstream FEX full TSO" env $T $U ./threads-x86 8
t "threads 20, upstream FEX full TSO" env $T $U ./threads-x86 20
t "litmus mp, upstream FEX full TSO" env $T $U ./mp-x86 mp 20000
timeout 3600 env $T $U ./pigz -n -p 4 -c in.tar >/tmp/out 2>/tmp/err
r "pigz, upstream FEX full TSO: exit $?, $([ "$(md5sum </tmp/out | cut -c1-8)" = "$(cat want.md5)" ] && echo ok || echo WRONG)"
env $P TSO_VIEWS_LOG=1 timeout 1800 $F ./threads-x86 20 >/tmp/out 2>/tmp/log
r "logged run: exit $?, $(grep -c 'compiled rip' /tmp/log) compiles"
grep -v 'compiled rip' /tmp/log | tail -n 25 | sed 's/^/TSOTEST log: /'
r "done"
poweroff

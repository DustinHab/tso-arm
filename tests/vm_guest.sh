#!/bin/sh
# Runs inside the test VM (tests/vm_run.sh): tso-arm on the emulated core, results as TSOTEST lines on the console.
# The payload in /root/t: FEX built for Armv8.0 (fex/build_generic.sh), x86-64 tests, pigz's library built for
# Armv8.0 and for FEAT_LRCPC, a small input and its expected checksum.
exec >/dev/ttyAMA0 2>&1
cd /root/t
r() { echo "TSOTEST $*"; }
F=/root/t/fex/bin/FEX
features=$(grep -m1 '^Features' /proc/cpuinfo | cut -d: -f2)
r "core: $(grep -m1 'CPU part' /proc/cpuinfo | cut -d: -f2) features:$features"
r "kernel: $(uname -r), page size $(getconf PAGESIZE)"
echo "$features" | grep -qw lrcpc && lib=pigz-rcpc.so || lib=pigz-v80.so
r "library: $lib"
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
t() { # label, command...
    label=$1
    shift
    timeout 1800 "$@" >/tmp/out 2>/tmp/err
    rc=$?
    r "$label: exit $rc | $(tail -n 1 /tmp/out) | $(grep -v '^$' /tmp/err | tail -n 2 | tr '\n' ' ' | cut -c1-160)"
}
t "threads 8, protocol" env $P $F ./threads-x86 8
t "threads 20, protocol (more than the view slots)" env $P $F ./threads-x86 20
for v in mp stack lb; do
    t "litmus $v, protocol" env $P $F ./mp-x86 $v 20000
done
t "litmus stack, FEX full TSO" env FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1 $F ./mp-x86 stack 20000
for cfg in fex-full protocol protocol-aot; do
    case $cfg in
    fex-full) vars="FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1" ;;
    protocol) vars="$P" ;;
    protocol-aot) vars="$P TSO_AOT=/root/t/$lib" ;;
    esac
    s=$(date +%s)
    timeout 3600 env $vars $F ./pigz -n -p 4 -c in.tar >/tmp/out 2>/tmp/err
    rc=$?
    e=$(date +%s)
    [ "$(md5sum </tmp/out | cut -c1-8)" = "$(cat want.md5)" ] && ok=ok || ok=WRONG
    r "pigz, $cfg: exit $rc, $ok, $((e - s)) s | $(grep -v '^$' /tmp/err | tail -n 1 | cut -c1-100)"
done
r "done"
poweroff

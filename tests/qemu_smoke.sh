#!/bin/sh
# Test machine: whether FEX runs under QEMU's user mode at all (upstream FEX and the tso-arm build, with and without
# the views), on an x86-64 hello-world-sized program.
#   tests/qemu_smoke.sh
cd "$(dirname "$0")/.."
Q=$HOME/opt/qemu-user/usr/bin/qemu-aarch64
t() {
    label=$1
    shift
    out=$(timeout 300 "$@" 2>&1 | tail -n 2 | tr '\n' ' ' | cut -c1-120)
    echo "$label: exit $? | $out"
}
t "native threads-x86 under qemu? (x86, should fail)" $Q -cpu max build/threads-x86 2
t "upstream FEX, qemu max" env FEX_DISABLETELEMETRY=1 $Q -cpu max $HOME/opt/fex/bin/FEX build/threads-x86 2
t "tso-arm FEX, no views, qemu max" env FEX_DISABLETELEMETRY=1 $Q -cpu max $HOME/opt/fex-views/bin/FEX build/threads-x86 2
t "tso-arm FEX, views, qemu max" env FEX_DISABLETELEMETRY=1 TSO_VIEWS=1 $Q -cpu max $HOME/opt/fex-views/bin/FEX build/threads-x86 2
t "upstream FEX, qemu max, FEXServer off" env FEX_DISABLETELEMETRY=1 FEX_SERVERSOCKETPATH=/nonexistent $Q -cpu max $HOME/opt/fex/bin/FEX build/threads-x86 2
t "qemu strace of upstream FEX (last calls)" env FEX_DISABLETELEMETRY=1 $Q -strace -cpu max $HOME/opt/fex/bin/FEX build/threads-x86 2

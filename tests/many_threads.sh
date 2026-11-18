#!/bin/sh
# Test machine: more threads at once than the page protocol has view slots for (15 on a 39-bit address space). The
# threads test with 12, 15, 16, 32 and 64 threads, and the three workloads with 32 threads (outputs checked), under
# the protocol with their translated functions; each run's last protocol message.
#   tests/many_threads.sh
cd "$(dirname "$0")/.."
F=$HOME/opt/fex-views/bin/FEX
C=$PWD/build
P="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_MULTIBLOCK=0 FEX_DISABLETELEMETRY=1 TSO_VIEWS_PROFILE=none"
for n in 12 15 16 32 64; do
    out=$(env $P $F build/threads-x86 $n 2>/tmp/mt.err | tail -n 1)
    printf 'threads %2d: exit %d | %s | %s\n' $n $? "$out" "$(grep -o 'tso-arm: [a-z].*' /tmp/mt.err | tail -n 1 | cut -c1-90)"
done
for w in pigz xz zstd; do
    case $w in
    zstd) args="-T32 -3 -f -q -c $C/corpus.tar" ;;
    pigz) args="-n -p 32 -c $C/corpus.tar" ;;
    xz) args="-T32 -6 --block-size=1MiB -c $C/corpus8.tar" ;;
    esac
    s=$(date +%s%N)
    env $P TSO_AOT=$PWD/out/aot/$w.so $F build/x86/$w $args >/dev/shm/mt-out 2>/tmp/mt.err
    rc=$?
    e=$(date +%s%N)
    # xz's output depends on the block size; zstd's and pigz's do not depend on the thread count
    if [ $w = xz ]; then
        want=$(build/arm64/xz -T32 -6 --block-size=1MiB -c $C/corpus8.tar | md5sum | cut -c1-8)
    else
        want=$(grep "^$w " build/expected.md5 | cut -d' ' -f2)
    fi
    ok=ok
    [ "$(md5sum </dev/shm/mt-out | cut -c1-8)" != "$want" ] && ok=WRONG
    printf '%-5s 32 threads: exit %d, %d ms, %s | %s\n' $w $rc $(( (e - s) / 1000000 )) $ok \
        "$(grep -o 'tso-arm: [a-z].*' /tmp/mt.err | tail -n 1 | cut -c1-90)"
done
rm -f /dev/shm/mt-out

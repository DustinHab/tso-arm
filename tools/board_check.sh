#!/bin/sh
# On a new Arm board: whether tso-arm can run there, and (with --run) the whole chain: FEX with the views built,
# the functions to translate ahead of time chosen from a profile, correctness checked, efficiency measured.
#   tools/board_check.sh [--run]
# Needs the workloads (build/x86, build/arm64, build/corpus*.tar, build/expected.md5: bench/build_native.sh and the
# x86 builds from study/build_static.sh) for --run.
cd "$(dirname "$0")/.."
ok=1
say() { printf '%-28s %s\n' "$1" "$2"; }
bad() { say "$1" "$2  <- needed"; ok=0; }

[ "$(uname -m)" = aarch64 ] && say "architecture" "aarch64" || bad "architecture" "$(uname -m)"
ps=$(getconf PAGESIZE)
[ "$ps" = 4096 ] && say "page size" "4 KB" || bad "page size" "$((ps / 1024)) KB (FEX and the views need a 4 KB-page kernel)"
cfg=/boot/config-$(uname -r)
va=$( (cat $cfg 2>/dev/null || zcat /proc/config.gz 2>/dev/null) | sed -n 's/^CONFIG_ARM64_VA_BITS=//p')
say "virtual address bits" "${va:-unknown} (39 or more: 15 threads with views of their own, more share them in the fallback)"
model=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | sort -u | tr '\n' ' ')
say "cores" "$(nproc), ${model:-unknown model}"
f=$(grep -m1 '^Features' /proc/cpuinfo)
has() { echo "$f" | grep -qw "$1" && echo yes || echo no; }
say "FEAT_LRCPC (ldapr)" "$(has lrcpc) (no: ldar instead, slower)"
say "FEAT_LRCPC2 (ldapur)" "$(has ilrcpc) (yes: unaligned ordered loads could be cheaper; not used yet)"
say "FEAT_LSE2 (unaligned atomics)" "$(has uscat)"
say "FEAT_LSE (atomics)" "$(has atomics)"
for t in clang python3 perf cmake ninja git; do
    command -v $t >/dev/null && say "tool $t" "found" || bad "tool $t" "missing"
done
python3 -c 'import capstone' 2>/dev/null && say "python capstone" "found" || bad "python capstone" "missing (pip install capstone)"
[ $ok = 1 ] && echo "=> tso-arm can run here" || echo "=> missing requirements"

if [ "$1" = --run ] && [ $ok = 1 ]; then
    set -e
    sh fex/build_views.sh && tail -n 1 out/build_views.log
    sh fex/link_symbols.sh >/dev/null
    for w in pigz xz zstd; do
        sh aot/auto.sh $w | tail -n 2
        sh aot/$w.sh
    done
    sh aot/stub_check.sh 200000
    sh tests/many_threads.sh
    sh bench/efficiency.sh
fi

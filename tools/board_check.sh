#!/bin/sh
# On a new Arm board: whether tso-arm can run there, and (with --run) the whole chain: FEX with the views built,
# the functions to translate ahead of time chosen from a profile, correctness checked, efficiency measured.
#   tools/board_check.sh [--run]
# Needs the workloads (build/x86, build/arm64, build/corpus*.tar, build/expected.md5: bench/build_native.sh and the
# x86 builds from study/build_static.sh) for --run.
cd "$(dirname "$0")/.."
ok=1
say() { printf '%-30s %s\n' "$1" "$2"; }
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
say "FEAT_LRCPC2 (ldapur)" "$(has ilrcpc) (yes: translated code orders accesses with an offset in one instruction)"
say "FEAT_LSE2 (unaligned atomics)" "$(has uscat)"
say "FEAT_LSE (atomics)" "$(has atomics)"
command -v readelf >/dev/null && say "readelf" "found" || bad "readelf" "missing (binutils)"
gv=$(getconf GNU_LIBC_VERSION 2>/dev/null | sed 's/^glibc //')
case $gv in
2.3[5-9]* | 2.[4-9]* | [3-9].*) say "glibc" "$gv" ;;
*) say "glibc" "${gv:-unknown} (the prebuilt FEX needs 2.35 or newer; 'tso-arm install' builds it from source here)" ;;
esac
# what only 'learn' needs, and only a build of FEX from source
missing=""
for t in clang python3 perf; do
    command -v $t >/dev/null || missing="$missing $t"
done
cv=$(python3 -c 'import capstone; print(capstone.__version__)' 2>/dev/null)
case $cv in
5.* | [6-9].*) ;;
"") missing="$missing capstone" ;;
*) missing="$missing capstone-5 (found $cv)" ;;
esac
[ -z "$missing" ] && say "for 'tso-arm learn'" "all found" ||
    say "for 'tso-arm learn'" "missing:$missing (apt: clang python3 python3-capstone linux-perf; pip install --user capstone)"
missing=""
for t in git cmake ninja clang clang++ ld.lld python3; do
    command -v $t >/dev/null || missing="$missing $t"
done
[ -z "$missing" ] && say "to build FEX from source" "all found" ||
    say "to build FEX from source" "missing:$missing (only without the prebuilt FEX)"
fex=""
for f in "$TSO_ARM_FEX" "${TSO_ARM_PREFIX:-$HOME/.local/opt/tso-arm}/bin/FEX" "$HOME/opt/fex-views/bin/FEX"; do
    if [ -n "$f" ] && [ -x "$f" ]; then
        fex=$f
        break
    fi
done
b="$(dirname "$(dirname "${fex:-/x/x}")")/BUILD"
if [ -f "$b" ]; then
    say "FEX with the tso-arm patches" "$fex ($(sed -n 's/^built //p' "$b"))"
else
    say "FEX with the tso-arm patches" "${fex:-not installed yet ('tso-arm install')}"
fi
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

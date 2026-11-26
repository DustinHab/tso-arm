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
ps=$(sh tools/pages_hint.sh --size)
if [ "$ps" = 4096 ]; then
    say "page size" "4 KB"
else
    bad "page size" "$([ -n "$ps" ] && echo "$((ps / 1024)) KB" || echo unknown) (FEX and the views need a 4 KB-page kernel)"
    sh tools/pages_hint.sh | sed 's/^/    /'
fi
# the kernel's configuration where distributions keep it (Debian, openSUSE; Fedora; Arch), else the highest address
# this process has (its stack's: 0xffff... with 48 bits, 0x7f... with 39), as in a container
r=$(uname -r)
va=$( (cat /boot/config-$r /lib/modules/$r/config 2>/dev/null; zcat /proc/config.gz 2>/dev/null) | sed -n 's/^CONFIG_ARM64_VA_BITS=//p' | head -n 1)
if [ -z "$va" ]; then
    top=$(sed -n '$s/^[0-9a-f]*-\([0-9a-f]*\) .*/\1/p' /proc/self/maps)
    case $top in
    [1]*) b=1 ;; [23]*) b=2 ;; [4-7]*) b=3 ;; [89a-f]*) b=4 ;; *) b="" ;;
    esac
    [ -n "$b" ] && va="$((4 * (${#top} - 1) + b)), from this process's addresses"
fi
say "virtual address bits" "${va:-unknown} (39 or more: 15 threads with views of their own, more share them in the fallback)"
model=$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | sort -u | tr '\n' ' ')
# without lscpu (util-linux): the cores' part numbers, which lscpu turns into names
[ -n "$model" ] || model=$(sed -n 's/^CPU part[[:space:]]*: *0x/part 0x/p' /proc/cpuinfo | sort -u | tr '\n' ' ')
say "cores" "$(nproc), ${model:-unknown model}"
f=$(grep -m1 '^Features' /proc/cpuinfo)
has() { echo "$f" | grep -qw "$1" && echo yes || echo no; }
say "FEAT_LRCPC (ldapr)" "$(has lrcpc) (no: ldar instead, slower)"
say "FEAT_LRCPC2 (ldapur)" "$(has ilrcpc) (yes: translated code orders accesses with an offset in one instruction)"
say "FEAT_LSE2 (unaligned atomics)" "$(has uscat)"
if command -v clang >/dev/null; then
    d=$(mktemp -d)
    m=armv8-a
    [ "$(has lrcpc)" = yes ] && m=armv8.2-a+rcpc
    if clang -O1 -march=$m -o "$d/probe" aot/unaligned_probe.c 2>/dev/null; then
        case $("$d/probe" | sed -n 's/^within16 //p') in
        yes) r="allowed within 16 bytes (translated code needs no barrier for them)" ;;
        no) r="fault (translated code puts a barrier after them instead)" ;;
        *) r="unknown" ;;
        esac
        say "unaligned ldapr, stlr" "$r"
    fi
    rm -rf "$d"
fi
say "FEAT_LSE (atomics)" "$(has atomics)"
command -v readelf >/dev/null && say "readelf" "found (for 'learn')" || say "readelf" "missing (binutils): only 'learn' needs it"
LD=/lib/ld-linux-aarch64.so.1
gv=$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')
[ -n "$gv" ] || [ ! -x "$LD" ] || gv=$("$LD" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
case $gv in
2.3[5-9]* | 2.[4-9]* | [3-9].*) say "C library" "glibc $gv" ;;
2.*) say "C library" "glibc $gv (the prebuilt FEX needs 2.35 or newer; 'tso-arm install --source' builds FEX here)" ;;
*)
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        bad "C library" "musl (FEX needs glibc: a container of a distribution with glibc runs tso-arm)"
    else
        say "C library" "unknown (FEX needs glibc)"
    fi
    ;;
esac
# user namespaces, which Steam requires and AppArmor restricts on Ubuntu 23.10 and newer ('tso-arm userns')
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    if [ -f /etc/apparmor.d/tso-arm-fex ]; then
        say "user namespaces" "restricted by AppArmor, allowed to tso-arm's FEX"
    else
        say "user namespaces" "restricted by AppArmor (Steam requires them: sudo tso-arm userns allow)"
    fi
else
    say "user namespaces" "not restricted"
fi
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
# where 'tso-arm run' looks, in its order: the prebuilt FEX of a release package (fex/prebuilt) among them
for f in "$TSO_ARM_FEX" "${TSO_ARM_PREFIX:-$HOME/.local/opt/tso-arm}/bin/FEX" "$PWD/fex/prebuilt/bin/FEX" "$HOME/opt/fex-views/bin/FEX"; do
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
# whether it starts here: glibc's dynamic loader lists the libraries it lacks, and versions too old
if [ -n "$fex" ]; then
    if [ ! -x "$LD" ]; then
        bad "FEX starts" "no: it needs glibc's dynamic loader ($LD)"
    else
        l=$("$LD" --list "$fex" 2>&1 | grep 'not found' | sed 's/^[[:space:]]*//; s/ (required by .*//' | tr '\n' ';')
        [ -z "$l" ] && say "FEX starts" "yes" || bad "FEX starts" "no: ${l%;}"
    fi
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

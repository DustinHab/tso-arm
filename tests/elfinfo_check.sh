#!/bin/sh
# tso-arm reads a program's machine, kind and build ID without binutils (elfinfo in bin/tso-arm). This compares it
# with readelf over the ELF files of a directory tree: x86-64 and i386 programs and libraries of a root file system.
#   tests/elfinfo_check.sh [DIRECTORY ...]   (default: the x86-64 root file system tso-arm rootfs fetched)
# Prints each difference and a count; exit status 1 if there was one.
cd "$(dirname "$0")/.."
command -v readelf >/dev/null || {
    echo "elfinfo_check: needs readelf to compare with"
    exit 2
}
eval "$(sed -n '/^elfinfo() {/,/^}/p' bin/tso-arm)"
[ $# -gt 0 ] || set -- "$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04/usr/bin" \
    "$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04/usr/lib/x86_64-linux-gnu" \
    "$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04/usr/lib/i386-linux-gnu"
n=0 bad=0
list=$(mktemp)
find "$@" -maxdepth 1 -type f >"$list" 2>/dev/null
while IFS= read -r f; do
    [ "$(head -c 4 <"$f" | tail -c 3)" = ELF ] || continue # ELF files, not archives of them
    h=$(LC_ALL=C readelf -h "$f" 2>/dev/null) || continue
    case $h in
    *X86-64*) m=x86-64 ;;
    *"Intel 80386"*) m=i386 ;;
    *) m=other ;;
    esac
    if [ $m = other ]; then
        k=other
    elif LC_ALL=C readelf -lW "$f" 2>/dev/null | grep -q 'INTERP'; then
        k=dynamic
    elif echo "$h" | grep -q 'Type:.*DYN'; then
        k=pie
    elif echo "$h" | grep -q 'Type:.*EXEC'; then
        k=static
    else
        k=other
    fi
    [ $m = other ] && k=other
    id=$(LC_ALL=C readelf -n "$f" 2>/dev/null | sed -n 's/^ *Build ID: *//p' | head -n 1 | cut -c1-16)
    want="$m $k ${id:--}"
    [ $m = other ] && want="other other -"
    got=$(elfinfo "$f")
    [ $m = other ] && got=$(echo "$got" | sed 's/ [^ ]*$/ -/')
    n=$((n + 1))
    if [ "$got" != "$want" ]; then
        bad=$((bad + 1))
        echo "differs: $f: readelf '$want', tso-arm '$got'"
    fi
done <"$list"
rm -f "$list"
echo "elfinfo_check: $n ELF files, $bad differ"
[ $bad = 0 ]

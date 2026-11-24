#!/bin/sh
# On an x86-64 Ubuntu machine with wine64 and the MinGW compiler installed (apt install wine64 gcc-mingw-w64-x86-64):
# Wine with every shared library it and its Unix-side modules need, the dynamic loader, a few files of /etc, and the
# Windows test programs of tests/win built for it, packed for the Arm machine (tests/wine_check.sh runs them).
#   tools/wine_rootfs.sh OUT.tar.zst
set -e
[ $# = 1 ] || { echo "usage: tools/wine_rootfs.sh OUT.tar.zst" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "run this on an x86-64 machine" >&2; exit 1; }
cd "$(dirname "$0")/.."
out=$(readlink -f "$1")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
[ -x /usr/lib/wine/wine64 ] || { echo "missing: wine64 (/usr/lib/wine/wine64)" >&2; exit 1; }
mkdir -p $T/root/opt/tso-arm-tests
for c in tests/win/*.c; do
    x86_64-w64-mingw32-gcc -O2 -o $T/root/opt/tso-arm-tests/$(basename "$c" .c).exe "$c"
done
list=$T/files
{
    echo /usr/lib/wine
    echo /usr/lib/x86_64-linux-gnu/wine
    echo /usr/share/wine
    echo /lib64/ld-linux-x86-64.so.2
    echo /etc/ld.so.cache
    echo /etc/fonts
    for b in wine wine64 wineserver wineboot; do command -v $b || true; done
} >$list
# what Wine loads by name at run time (dlopen: FreeType, fontconfig, GnuTLS), then the shared libraries of every
# ELF file, to a fixed point
for l in libfreetype.so.6 libfontconfig.so.1 libgnutls.so.30; do
    p=$(ldconfig -p | awk -v l=$l '$1 == l && /x86-64/ { print $NF; exit }')
    [ -n "$p" ] && echo "$p" >>$list
done
: >$T/seen
while :; do
    sort -u $list -o $list
    find $(cat $list) -type f 2>/dev/null | while read -r f; do
        grep -qxF "$f" $T/seen && continue
        echo "$f" >>$T/seen
        head -c 4 "$f" | grep -q 'ELF' || continue
        ldd "$f" 2>/dev/null | awk '/=> \// { print $3 }'
    done >$T/new
    n=$(sort -u $T/new | grep -vxF -f $list | wc -l)
    cat $T/new >>$list
    [ "$n" = 0 ] && break
done
sort -u $list -o $list
echo "$(wc -l <$list) paths, $(du -chL $(cat $list) 2>/dev/null | tail -n 1 | cut -f1)"
tar -C / -chf $T/root.tar $(sed 's|^/||' $list) 2>/dev/null || true
tar -C $T/root -rf $T/root.tar opt
zstd -q -T0 -12 $T/root.tar -o "$out" -f
echo "$out: $(du -h "$out" | cut -f1)"

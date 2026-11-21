#!/bin/sh
# On an x86-64 Linux machine: a root file system with the programs tests/compat.sh runs, taken from this machine (the
# programs, every shared library they and Python's extension modules need, the dynamic loader, Python's standard
# library, the distribution's JDK), packed for the Arm machine. Nothing is installed or changed here.
#   tools/compat_rootfs.sh OUT.tar.zst
set -e
[ $# = 1 ] || { echo "usage: tools/compat_rootfs.sh OUT.tar.zst" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "run this on an x86-64 machine" >&2; exit 1; }
out=$(readlink -f "$1")
# the distribution's programs, not others the machine may have in /usr/local or /opt (GitHub's runners bring Node)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
list=$T/files
: >$list
need() { # program names: the program itself; for a shell wrapper its exec target's whole directory (7-Zip's
    # codecs, 7z.so, lie beside the binary and are loaded by it, which ldd does not show)
    for p; do
        w=$(command -v "$p") || { echo "missing: $p" >&2; exit 1; }
        echo "$w" >>$list
        if head -c 2 "$w" | grep -q '#!'; then
            sed -n 's/^exec "\{0,1\}\(\/[^" ]*\).*/\1/p' "$w" | while read -r t; do dirname "$t"; done >>$list
        fi
    done
}
need sort python3 node ffmpeg 7z
# the distribution's Java, its whole directory (the JVM finds its libraries and modules from where its binary lies;
# GitHub's runners bring other JDKs beside it)
jdk=$(ls -d /usr/lib/jvm/java-*-openjdk-amd64 2>/dev/null | sort -V | tail -n 1)
[ -n "$jdk" ] && [ -x "$jdk/bin/javac" ] || { echo "missing: a JDK in /usr/lib/jvm (default-jdk-headless)" >&2; exit 1; }
echo "$jdk" >>$list
py=$(python3 -c 'import sys; print(sys.prefix + "/lib/python" + sys.version[:sys.version.index(".", 2)])')
echo "$py" >>$list
# the JavaScript files a distribution's Node keeps outside its library ("externalized builtins")
libnode=$(ldd "$(command -v node)" | awk '/libnode/ { print $3 }')
if [ -n "$libnode" ]; then
    strings "$libnode" | grep -o '/usr/share/nodejs/[A-Za-z0-9_./@-]*' | sort -u | while read -r f; do
        [ -e "$f" ] && echo "$f"
    done >>$list
fi
echo /lib64/ld-linux-x86-64.so.2 >>$list
echo /etc/ld.so.cache >>$list
# shared libraries of every ELF file collected so far, to a fixed point
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
# -h: symbolic links become the files they name, so the root file system needs no links of the host's layout
# (and without what a JDK needs only to build others: its modules for jlink, headers, manual pages)
tar -C / -chf - --exclude='usr/lib/jvm/*/jmods' --exclude='usr/lib/jvm/*/include' --exclude='usr/lib/jvm/*/man' \
    --exclude='usr/lib/jvm/*/docs' $(sed 's|^/||' $list) 2>/dev/null | zstd -q -T0 -12 -o "$out" -f
echo "$out: $(du -h "$out" | cut -f1)"

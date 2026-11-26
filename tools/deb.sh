#!/bin/sh
# A Debian package (Debian, Ubuntu, Raspberry Pi OS on 64-bit Arm) from a release package:
#   tools/deb.sh RELEASE-TARBALL OUTDIR
#   RELEASE-TARBALL   tso-arm-VERSION-linux-arm64.tar.gz as tools/package.sh makes it, FEX prebuilt in fex/prebuilt
#   OUTDIR/tso-arm_VERSION_arm64.deb
# It installs as tools/get.sh does for every user: the release into /opt/tso-arm/VERSION, /opt/tso-arm/current the
# link to it, the command as /usr/bin/tso-arm. Configured, it registers x86 programs with binfmt_misc; removed, it
# unregisters them; purged, it removes the root file system 'sudo tso-arm rootfs' fetched for every user as well (the
# maintainer scripts in tools/deb/). Built with dpkg-deb alone.
set -e
H=$(cd "$(dirname "$0")" && pwd)
D=/opt/tso-arm
MAINTAINER="DustinHab <142697073+DustinHab@users.noreply.github.com>"
die() {
    echo "deb: $*" >&2
    exit 1
}
[ $# = 2 ] || die "usage: tools/deb.sh RELEASE-TARBALL OUTDIR"
pkg=$1
out=$2
v=$(basename "$pkg" | sed -n 's/^tso-arm-\([0-9][0-9.]*\)-linux-arm64\.tar\.gz$/\1/p')
[ -n "$v" ] || die "$pkg is not named like a release package (tso-arm-VERSION-linux-arm64.tar.gz)"
command -v dpkg-deb >/dev/null || die "needs dpkg-deb"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
tar -xzf "$pkg" -C "$t" || die "$pkg is not a release package"
s=$t/tso-arm-$v
[ -x "$s/bin/tso-arm" ] && [ -x "$s/fex/prebuilt/bin/FEX" ] && [ "$(cat "$s/VERSION")" = "$v" ] ||
    die "$pkg holds no tso-arm $v with its prebuilt FEX"

r=$t/root
mkdir -p "$r$D" "$r/usr/bin" "$r/usr/share/doc/tso-arm" "$r/DEBIAN"
mv "$s" "$r$D/$v"
# bin/tso-arm and tools/get.sh leave an installation with this file to dpkg: update, uninstall, get.sh as root
echo deb >"$r$D/$v/PACKAGE"
ln -s "$v" "$r$D/current"
ln -s "$D/current/bin/tso-arm" "$r/usr/bin/tso-arm"

# the licenses: tso-arm's own, and where those of FEX and the libraries built into it are
doc=$r/usr/share/doc/tso-arm
{
    echo "tso-arm $v, https://github.com/DustinHab/tso-arm"
    echo
    cat "$r$D/$v/LICENSE"
    echo
    echo "The package carries FEX (https://github.com/FEX-Emu/FEX), built with the tso-arm patches, in"
    echo "$D/$v/fex/prebuilt. The licenses of FEX and of the libraries built into it are in"
    echo "$D/$v/fex/prebuilt/licenses, FEX's own in licenses/FEX."
} >"$doc/copyright"
# a changelog in Debian's format, dated as the release's files are (git archive gives them the commit's time); what
# changed is in CHANGELOG.md
{
    echo "tso-arm ($v) stable; urgency=medium"
    echo
    echo "  * tso-arm $v: $D/$v/CHANGELOG.md lists what it changed."
    echo
    echo " -- $MAINTAINER  $(LC_ALL=C date -u -R -r "$r$D/$v/VERSION")"
} | gzip -9n >"$doc/changelog.gz"

# what 'tso-arm run' needs beyond the essential packages (sh, coreutils' od, sed, grep, getent) and awk (essential in
# all but name; lintian counts a dependency on it as needless): the C and C++ libraries the prebuilt FEX is linked with
# (built on Ubuntu 22.04: glibc 2.35, GLIBCXX_3.4.30 of GCC 12). 'tso-arm rootfs' needs curl and unsquashfs (FEX's
# FEXRootFSFetcher), 'learn' binutils, Python with Capstone 5, clang and perf, --gpu the host's Vulkan library.
size=$(du -sk --apparent-size "$r" | cut -f1)
cat >"$r/DEBIAN/control" <<EOF
Package: tso-arm
Version: $v
Architecture: arm64
Maintainer: $MAINTAINER
Installed-Size: $size
Depends: libc6 (>= 2.35), libgcc-s1 (>= 4.5), libstdc++6 (>= 12)
Recommends: curl, squashfs-tools
Suggests: binutils, python3, python3-capstone, clang, linux-perf | linux-tools-generic, libvulkan1
Section: otherosfs
Priority: optional
Homepage: https://github.com/DustinHab/tso-arm
Description: x86 Linux programs on 64-bit Arm with x86 memory order kept
 tso-arm runs x86-64 and 32-bit x86 Linux programs on 64-bit Arm Linux.
 Multithreaded x86 programs rely on x86's memory order, which Arm processors
 do not guarantee. tso-arm orders only the memory that threads really share:
 each thread sees memory through views of its own, and the processor's page
 protection reports the moment a second thread touches a page. A program's
 hot functions can be translated ahead of time ('tso-arm learn').
 .
 It is built on FEX, which the package carries prebuilt with the tso-arm
 patches. x86 programs started directly and x86-64 container images
 (docker run --platform linux/amd64) run through it as well, registered with
 binfmt_misc. Dynamically linked programs need an x86-64 root file system,
 which 'tso-arm rootfs' fetches. It needs a kernel with 4 KB pages.
EOF
for m in preinst postinst prerm postrm; do
    install -m 755 "$H/deb/$m" "$r/DEBIAN/$m"
done
(cd "$r" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 md5sum) >"$r/DEBIAN/md5sums"
chmod 644 "$r/DEBIAN/control" "$r/DEBIAN/md5sums"
chmod -R u+rwX,go+rX,go-w "$r"

mkdir -p "$out"
deb=$out/tso-arm_${v}_arm64.deb
dpkg-deb --root-owner-group -Zxz --build "$r" "$deb"
dpkg-deb --info "$deb" | sed -n '/Package:/,$p'
ls -l "$deb"

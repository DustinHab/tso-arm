#!/bin/sh
# An RPM package (Fedora, openSUSE on 64-bit Arm) from a release package, as tools/deb.sh makes the Debian one:
#   tools/rpm.sh RELEASE-TARBALL OUTDIR
#   RELEASE-TARBALL   tso-arm-VERSION-linux-arm64.tar.gz as tools/package.sh makes it, FEX prebuilt in fex/prebuilt
#   OUTDIR/tso-arm-VERSION-1.aarch64.rpm
# The same files in the same places as the Debian package (/opt/tso-arm/VERSION, /opt/tso-arm/current, the command as
# /usr/bin/tso-arm) and its maintainer scripts (tools/deb/): installed, it registers x86 programs with binfmt_misc;
# removed, it unregisters them and removes the root file system 'sudo tso-arm rootfs' fetched for every user as well.
# Built with rpmbuild (Debian and Ubuntu: apt install rpm) from tools/rpm/tso-arm.spec.in.
set -e
H=$(cd "$(dirname "$0")" && pwd)
die() {
    echo "rpm: $*" >&2
    exit 1
}
[ $# = 2 ] || die "usage: tools/rpm.sh RELEASE-TARBALL OUTDIR"
pkg=$1
out=$2
v=$(basename "$pkg" | sed -n 's/^tso-arm-\([0-9][0-9.]*\)-linux-arm64\.tar\.gz$/\1/p')
[ -n "$v" ] || die "$pkg is not named like a release package (tso-arm-VERSION-linux-arm64.tar.gz)"
command -v rpmbuild >/dev/null || die "needs rpmbuild (apt install rpm, dnf install rpm-build, zypper install rpm-build)"
for m in preinst postinst prerm postrm; do
    [ -f "$H/deb/$m" ] || die "no maintainer script $H/deb/$m"
done
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
tar -xzf "$pkg" -C "$t" || die "$pkg is not a release package"
s=$t/tso-arm-$v
[ -x "$s/bin/tso-arm" ] && [ -x "$s/fex/prebuilt/bin/FEX" ] && [ "$(cat "$s/VERSION")" = "$v" ] ||
    die "$pkg holds no tso-arm $v with its prebuilt FEX"
chmod -R u+rwX,go+rX,go-w "$s"

# the spec: the version, the tree, and the Debian package's maintainer scripts without their first line, a % doubled
# (rpm reads it as the start of a macro)
awk -v v="$v" -v tree="$s" -v d="$H/deb" '
function body(f,   l, n) {
    while ((getline l < f) > 0) {
        if (n++ == 0 && l ~ /^#!/)
            continue
        gsub(/%/, "%%", l)
        print l
    }
    close(f)
}
$0 == "@PREINST@" { body(d "/preinst"); next }
$0 == "@POSTINST@" { body(d "/postinst"); next }
$0 == "@PRERM@" { body(d "/prerm"); next }
$0 == "@POSTRM@" { body(d "/postrm"); next }
{ gsub(/@VERSION@/, v); gsub(/@TREE@/, tree); print }
' "$H/rpm/tso-arm.spec.in" >"$t/tso-arm.spec"

mkdir -p "$out"
out=$(cd "$out" && pwd)
rpmbuild -bb --target aarch64 \
    --define "_topdir $t/build" \
    --define "_rpmdir $out" \
    --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
    --define "_binary_payload w6.xzdio" \
    "$t/tso-arm.spec" >"$t/rpmbuild.log" 2>&1 || {
    cat "$t/rpmbuild.log" >&2
    die "rpmbuild failed"
}
r=$out/tso-arm-$v-1.aarch64.rpm
[ -f "$r" ] || {
    cat "$t/rpmbuild.log" >&2
    die "rpmbuild made no $r"
}
rpm -qip "$r"
echo "requires:"
rpm -qp --requires "$r" | grep -v '^rpmlib(' | sed 's/^/  /'
ls -l "$r"

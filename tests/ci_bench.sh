#!/bin/sh
# Efficiency on any Arm machine with tso-arm installed (the CI runs it on GitHub's Arm runners): pigz, xz and zstd
# built from their official sources natively and for x86-64 (static, with a cross compiler), corpora from the
# machine's own files, `tso-arm learn` for each, then best of ROUNDS (default 3) natively, under FEX without ordering
# and with full TSO, and with tso-arm; outputs checked against the native ones. A markdown table to stdout (and to
# $GITHUB_STEP_SUMMARY).
#   tests/ci_bench.sh       CC_X86 (default x86_64-linux-gnu-gcc), ROUNDS
set -e
cd "$(dirname "$0")/.."
R=$PWD
T=$R/bin/tso-arm
S=$R/build/ci-src
N=$R/build/ci-native
X=$R/build/ci-x86
CCX=${CC_X86:-x86_64-linux-gnu-gcc}
rounds=${ROUNDS:-3}
J=$(nproc)
mkdir -p $S $N $X
fetch() { [ -f "$S/$2" ] || curl -sSfL -o "$S/$2" "$1"; }
fetch https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz zstd.tar.gz
fetch https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz xz.tar.gz
fetch https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz zlib.tar.gz
fetch https://github.com/madler/pigz/archive/refs/tags/v2.8.tar.gz pigz.tar.gz

build() { # DIR CC LDFLAGS-static|"" OUT
    d=$1 cc=$2 st=$3 out=$4
    rm -rf $d && mkdir -p $d && cd $d
    for t in zstd xz zlib pigz; do tar xzf $S/$t.tar.gz; done
    CF="-O2 -fno-pie -fno-stack-protector"
    make -s -C zstd-1.5.7/programs -j$J zstd CC=$cc CFLAGS="$CF" LDFLAGS="$st -no-pie" HAVE_ZLIB=0 HAVE_LZMA=0 HAVE_LZ4=0 >/dev/null
    (cd xz-5.8.4 && ./configure -q --host=$($cc -dumpmachine) --disable-shared --enable-static --disable-nls CC=$cc CFLAGS="$CF" >/dev/null)
    make -s -C xz-5.8.4 -j$J LDFLAGS="$( [ -n "$st" ] && echo -all-static) -no-pie" >/dev/null
    (cd zlib-1.3.1 && CC=$cc CFLAGS="$CF" ./configure --static >/dev/null && make -s -j$J libz.a >/dev/null)
    make -s -C pigz-2.8 -j$J pigz CC=$cc CFLAGS="$CF -I$d/zlib-1.3.1" LDFLAGS="$st -no-pie -L$d/zlib-1.3.1" >/dev/null
    cp zstd-1.5.7/programs/zstd xz-5.8.4/src/xz/xz pigz-2.8/pigz $out/
    cd $R
}
[ -x $N/pigz ] || build $R/build/ci-bn gcc "" $N
[ -x $X/pigz ] || build $R/build/ci-bx $CCX -static $X

# corpora of the machine's own files (text and binaries): 256 MB for pigz and zstd, whose runs would otherwise be
# dominated by the start, 64 MB for xz
C=$R/build/ci-corpus.tar
CL=$R/build/ci-corpus-large.tar
[ -f $CL ] || { tar cf - /usr/share/doc /usr/include /usr/lib/python3 /usr/lib/gcc /usr/bin 2>/dev/null | head -c 268435456 >$CL; }
[ -f $C ] || head -c 67108864 $CL >$C
args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $CL" ;;
    pigz) echo "-n -p 4 -c $CL" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C" ;;
    esac
}
for w in pigz xz zstd; do
    $T learn $X/$w $(args_of $w) >/dev/null
done

best() { # command... -> best wall time in ms, and the output checked
    b=""
    for i in $(seq $rounds); do
        s=$(date +%s%N)
        "$@" >/tmp/cb-out 2>/dev/null
        e=$(date +%s%N)
        t=$(( (e - s) / 1000000 ))
        [ -z "$b" ] || [ $t -lt $b ] && b=$t
        [ "$(md5sum </tmp/cb-out | cut -c1-32)" = "$want" ] || { echo "WRONG OUTPUT: $*" >&2; exit 1; }
    done
    echo $b
}
model=$(lscpu | sed -n 's/^Model name: *//p' | sort -u | tr '\n' ' ')
{
    echo "Efficiency on $(nproc) cores of $model(native time / time, best of $rounds, outputs checked)"
    echo
    echo "| | native | FEX, TSO off | FEX full TSO | tso-arm, page protocol | tso-arm + learned | learned, TSO off |"
    echo "|---|---|---|---|---|---|---|"
    echo "| x86 memory order kept | | no | yes | yes | yes | no |"
    for w in pigz xz zstd; do
        want=$($N/$w $(args_of $w) | md5sum | cut -c1-32)
        n=$(best $N/$w $(args_of $w))
        o=$(best $T run --mode unordered --no-aot $X/$w $(args_of $w))
        f=$(best $T run --mode full $X/$w $(args_of $w))
        p=$(best $T run --no-aot $X/$w $(args_of $w))
        l=$(best $T run $X/$w $(args_of $w))
        u=$(best $T run --mode unordered $X/$w $(args_of $w))
        echo "| $w | $n ms | $((100 * n / o)) % | $((100 * n / f)) % | $((100 * n / p)) % | $((100 * n / l)) % | $((100 * n / u)) % |"
    done
} | tee -a ${GITHUB_STEP_SUMMARY:-/dev/null}

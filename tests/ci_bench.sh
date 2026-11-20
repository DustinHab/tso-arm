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

# corpora of the machine's own files (text and binaries): 1 GB for zstd and 256 MB for pigz, whose runs would
# otherwise be dominated by the start, 64 MB for xz (several input files instead make native zstd slower than
# emulated: one file each)
CX=$R/build/ci-corpus-1g.tar
CL=$R/build/ci-corpus-large.tar
C=$R/build/ci-corpus.tar
[ -f $CX ] || { tar cf - /usr/share/doc /usr/include /usr/lib /usr/bin 2>/dev/null | head -c 1073741824 >$CX; }
[ -f $CL ] || head -c 268435456 $CX >$CL
[ -f $C ] || head -c 67108864 $CX >$C
args_of() {
    case $1 in
    zstd) echo "-T4 -3 -f -q -c $CX" ;;
    pigz) echo "-n -p 4 -c $CL" ;;
    xz) echo "-T4 -6 --block-size=2MiB -c $C" ;;
    esac
}
for w in pigz xz zstd; do
    $T learn $X/$w $(args_of $w) >$R/build/ci-learn-$w.log 2>&1 || { cat $R/build/ci-learn-$w.log; exit 1; }
done

once() { # command... -> wall time in ms, the output checked
    s=$(date +%s%N)
    "$@" >/tmp/cb-out 2>/dev/null
    e=$(date +%s%N)
    [ "$(md5sum </tmp/cb-out | cut -c1-32)" = "$want" ] || { echo "WRONG OUTPUT: $*" >&2; exit 1; }
    echo $(( (e - s) / 1000000 ))
}
lower() { if [ -z "$1" ] || [ "$2" -lt "$1" ]; then echo "$2"; else echo "$1"; fi; }
best() { # command... -> best wall time in ms, and the output checked
    b=""
    for i in $(seq $rounds); do
        t=$(once "$@")
        b=$(lower "$b" "$t")
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
        eval "native_$w=$n"
    done
    echo
    echo "What \`tso-arm learn\` chose:"
    echo
    for w in pigz xz zstd; do
        echo "- $w: $(grep -E '^(profile|chosen):' $R/build/ci-learn-$w.log | tr '\n' ' ')"
    done
    # what newer cores' features bring to the translated code: the learned library as built here against the same
    # code built without one of them, in alternating rounds on this machine. NOIMMO: offsets in the ordered accesses
    # (ldapur, stlur; FEAT_LRCPC2). NOU16: unaligned ldapr and stlr within 16 bytes (FEAT_LSE2, if the kernel allows)
    sw=""
    grep -qw ilrcpc /proc/cpuinfo && sw="$sw NOIMMO"
    clang -O1 -march=armv8.2-a+rcpc -o $R/build/ci-probe $R/aot/unaligned_probe.c 2>/dev/null &&
        $R/build/ci-probe >/dev/null 2>&1 && sw="$sw NOU16"
    if [ -n "$sw" ]; then
        echo
        echo "The learned code as built here against built without one of this core's features, x86 order kept,"
        echo "alternating rounds (offsets: \`ldapur\`, \`stlur\`; unaligned: \`ldapr\`, \`stlr\` within 16 bytes):"
        echo
        h="| | as built |" l="|---|---|"
        for s in $sw; do
            case $s in NOIMMO) h="$h without offsets |" ;; NOU16) h="$h without unaligned |" ;; esac
            l="$l---|"
        done
        echo "$h"
        echo "$l"
        A=${XDG_CACHE_HOME:-$HOME/.cache}/tso-arm/aot
        for w in pigz xz zstd; do
            c=$(ls $A/$w-*.c | head -n 1)
            for s in $sw; do
                env AOT_$s=1 sh $R/aot/build.sh $c $R/build/ci-$s-$w.so
                eval "b_$s="
            done
            want=$($N/$w $(args_of $w) | md5sum | cut -c1-32)
            eval "n=\$native_$w"
            a=""
            for i in $(seq $rounds); do
                t=$(once $T run $X/$w $(args_of $w))
                a=$(lower "$a" "$t")
                for s in $sw; do
                    t=$(once $T run --aot $R/build/ci-$s-$w.so $X/$w $(args_of $w))
                    eval "b_$s=\$(lower \"\$b_$s\" $t)"
                done
            done
            row="| $w | $((100 * n / a)) % |"
            for s in $sw; do
                eval "b=\$b_$s"
                row="$row $((100 * n / b)) % |"
            done
            echo "$row"
        done
    fi
} >$R/build/ci-bench.md # into a file, not through a pipe: a wrong output has to stop the script, not one side of a pipe
cat $R/build/ci-bench.md
[ -z "$GITHUB_STEP_SUMMARY" ] || cat $R/build/ci-bench.md >>"$GITHUB_STEP_SUMMARY"
for w in pigz xz zstd; do
    echo "== learn $w"
    cat $R/build/ci-learn-$w.log
done
# why native zstd is slower here than under FEX: its threads, natively and emulated
echo "== zstd threads"
for t in 1 4; do
    s=$(date +%s%N); $N/zstd -T$t -3 -f -q -c $CX >/dev/null; e=$(date +%s%N)
    s2=$(date +%s%N); $T run --mode unordered --no-aot $X/zstd -T$t -3 -f -q -c $CX >/dev/null; e2=$(date +%s%N)
    echo "-T$t: native $(( (e - s) / 1000000 )) ms, FEX without ordering $(( (e2 - s2) / 1000000 )) ms"
done
file $N/zstd $X/zstd | cut -c1-150

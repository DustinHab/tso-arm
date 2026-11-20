#!/bin/sh
# Where a workload's time goes on this machine with x86 order kept, with its translated functions and with FEX's own
# code alone (run as `tso-arm run` runs it): cycles and instructions, the time by part (translated library, FEX's
# code, FEX itself, the C library), the hottest functions of both runs, and the instruction kinds of the hottest
# translated function. Needs tests/ci_bench.sh before (programs, corpora, build/ci-aot-WORKLOAD.so).
#   tests/ci_profile.sh [WORKLOAD]       default zstd
# Elsewhere: PROFILE_X (directory of the x86 programs), PROFILE_LIB (the library), PROFILE_ARGS (the arguments).
set -e
cd "$(dirname "$0")/.."
R=$PWD
X=${PROFILE_X:-$R/build/ci-x86}
w=${1:-zstd}
case $w in
zstd) args="-T4 -3 -f -q -c $R/build/ci-corpus-1g.tar" ;;
pigz) args="-n -p 4 -c $R/build/ci-corpus-large.tar" ;;
xz) args="-T4 -6 --block-size=2MiB -c $R/build/ci-corpus.tar" ;;
*) echo "unknown workload $w" >&2; exit 1 ;;
esac
args=${PROFILE_ARGS:-$args}
F=${TSO_ARM_FEX:-${TSO_ARM_PREFIX:-$HOME/.local/opt/tso-arm}/bin/FEX}
lib=${PROFILE_LIB:-$R/build/ci-aot-$w.so}
[ -x "$F" ] && [ -f "$lib" ] && [ -x "$X/$w" ] || { echo "run tests/ci_bench.sh first" >&2; exit 1; }
export LC_ALL=C
P=$R/build/profile
mkdir -p $P
# as `tso-arm run` runs it; FEX names its blocks (guest address) for perf
base="TSO_VIEWS=1 FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_DISABLETELEMETRY=1 FEX_BLOCKJITNAMING=1"
for v in aot jit; do
    case $v in
    aot) e="$base FEX_MULTIBLOCK=0 TSO_AOT=$lib" ;;
    jit) e="$base" ;;
    esac
    env $e $F $X/$w $args >/dev/null # the page protocol's profile and the page cache, as a later run finds them
    env $e perf stat -x, -e cycles:u,instructions:u -o $P/$v.stat $F $X/$w $args >/dev/null
    env $e perf record -q -e cycles:u -o $P/$v.data $F $X/$w $args >/dev/null 2>&1
done
{
    echo "Profile of $w on $(lscpu | sed -n 's/^Model name: *//p' | sort -u | tr '\n' ' ')with x86 order kept"
    echo
    echo "| | cycles (user) | instructions | per cycle |"
    echo "|---|---|---|---|"
    for v in aot jit; do
        c=$(awk -F, '/cycles/ { print $1 }' $P/$v.stat)
        i=$(awk -F, '/instructions/ { print $1 }' $P/$v.stat)
        case $v in aot) label="translated functions + FEX" ;; jit) label="FEX alone" ;; esac
        echo "| $label | $c | $i | $(awk -v c=$c -v i=$i 'BEGIN { printf "%.2f", i / c }') |"
    done
    for v in aot jit; do
        echo
        case $v in aot) echo "By part, with the translated functions:" ;; jit) echo "By part, FEX alone:" ;; esac
        echo
        echo '```'
        perf report -i $P/$v.data --sort dso --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' | head -n 5
        echo '```'
        perf report -i $P/$v.data --sort sym --stdio 2>/dev/null >$P/$v.report
    done
    echo
    echo "By guest function (translated where the library has it, FEX's code otherwise):"
    echo
    python3 $R/tools/perf_guest.py $X/$w $P/aot.report $(awk -F, '/cycles/ { print $1 }' $P/aot.stat) \
        $P/jit.report $(awk -F, '/cycles/ { print $1 }' $P/jit.stat) 14
    f=$(perf report -i $P/aot.data --dsos $(basename $lib) --sort sym --stdio 2>/dev/null | grep -v '^#' | grep -v '^$' |
        head -n 1 | awk '{ print $NF }')
    echo
    echo "Instruction kinds in $f (share of its samples):"
    echo
    echo '```'
    perf annotate -i $P/aot.data --stdio -s $f 2>/dev/null | awk '/^ +[0-9.]+ +: +[0-9a-f]+:/ {
            split($0, a, ":"); p = a[1] + 0; ins = $0; sub(/^[^:]*:[^:]*:[ \t]*/, "", ins); split(ins, b, /[ \t]/)
            m = b[1]; k = "other"
            if (m ~ /^(ldapr|ldar)/) k = "ordered load"; else if (m ~ /^stlr/) k = "ordered store"
            else if (m == "dmb") k = "barrier"; else if (m ~ /^ld/) k = "plain load"; else if (m ~ /^st/) k = "plain store"
            else if (m ~ /^(b|bl|blr|br|ret|cbz|cbnz|tbz|tbnz)$/ || m ~ /^b\./) k = "branch"
            s[k] += p }
        END { for (k in s) printf "%6.2f %%  %s\n", s[k], k }' | sort -rn
    echo
    echo "hottest instructions:"
    perf annotate -i $P/aot.data --stdio -s $f 2>/dev/null | awk '/^ +[0-9.]+ +: +[0-9a-f]+:/' | sort -rn | head -n 16 |
        cut -c1-100
    echo '```'
} >$P/$w.md
cat $P/$w.md
[ -z "$GITHUB_STEP_SUMMARY" ] || cat $P/$w.md >>"$GITHUB_STEP_SUMMARY"

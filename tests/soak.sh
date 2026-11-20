#!/bin/sh
# Rare failures: multi-threaded programs of an x86-64 root file system, many times under tso-arm in several settings,
# each output against the program's output under FEX's full ordering. Races between threads and the page protocol
# (a fault handled while another thread rewrites code, notes section 44) show in a few runs of many, so every case
# runs ROUNDS times (default 20) in each setting:
#   default            as `tso-arm run` runs it, with the profile the rounds before left
#   fresh              without a profile: every run meets shared memory anew (escalations, traps, retranslations)
#   block              block by block (FEX_MULTIBLOCK=0, as with translated libraries): more block exits and links
# Needs the root file system `tso-arm rootfs` fetches (or ROOTFS=directory).
#   tests/soak.sh [ROUNDS]     exit status 1 if any run failed or gave another output
set -u
cd "$(dirname "$0")/.."
T=$PWD/bin/tso-arm
rounds=${1:-20}
if [ -z "${ROOTFS:-}" ]; then
    ROOTFS=$(ls -d "$HOME"/.local/share/fex-emu/RootFS/*/ 2>/dev/null | head -n 1)
fi
ROOTFS=${ROOTFS%/}
[ -n "$ROOTFS" ] && [ -x "$ROOTFS/usr/bin/bash" ] || {
    echo "no x86-64 root file system: 'tso-arm rootfs' fetches one (or set ROOTFS)"
    exit 2
}
export FEX_ROOTFS=$ROOTFS LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
B=$ROOTFS/usr/bin/bash
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
# a cache of its own: the default setting's profiles start from nothing and stay apart from the user's
export XDG_CACHE_HOME=$W/cache

# the inputs, made once under full ordering
$T run --mode full "$B" -c '
cd "$1" && git init -q -b main repo && cd repo || exit 1
awk '"'"'BEGIN {
    for (c = 1; c <= 60; c++) {
        printf "commit refs/heads/main\nmark :%d\ncommitter t <t@t> %d +0000\ndata 4\nc%03d\n", c, 1700000000 + c * 60, c
        if (c > 1) printf "from :%d\n", c - 1
        for (f = 0; f < 100; f++) {
            if (c > 1 && (f * 7 + c) % 5 != 0) continue
            s = ""
            for (j = 0; j < 300; j++) s = s sprintf("file %d line %d value %d\n", f, j, (j * 31 + f * 17 + (j % 10 == c % 10 ? c * 7 : 0)) % 100003)
            printf "M 100644 inline f%03d.txt\ndata %d\n%s\n", f, length(s), s
        }
    }
}'"'"' | git fast-import --quiet
seq 1 400000 | awk "{ printf \"%08x %d\n\", (\$1 * 2654435761) % 4294967296, \$1 }" >"$1/lines.txt"
' soak "$W" || { echo "soak: the inputs could not be made"; exit 2; }

cat >$W/threads.py <<'EOF'
import threading, hashlib
counts = {}
lock = threading.Lock()
def work(k):
    h = hashlib.sha256()
    for i in range(20000):
        h.update(str(i * k).encode())
        if i % 100 == 0:
            with lock:
                counts[i % 977] = counts.get(i % 977, 0) + k
    with lock:
        counts["h%d" % k] = h.hexdigest()
ts = [threading.Thread(target=work, args=(k,)) for k in range(1, 9)]
for t in ts: t.start()
for t in ts: t.join()
print(hashlib.sha256(repr(sorted(counts.items(), key=str)).encode()).hexdigest())
EOF

case_cmd() { # name -> a bash command line in the root file system ($W is the working directory)
    case $1 in
    git-repack) printf '%s\n' "rm -rf $W/g && cp -a $W/repo $W/g && git -C $W/g repack -a -d -f -q --threads=4 --window=20 && git -C $W/g fsck --strict --no-progress && git -C $W/g rev-list --objects --all | sort | md5sum" ;;
    xz-threads) printf '%s\n' "xz -T4 -6 --block-size=1MiB -c $W/lines.txt | xz -d | md5sum" ;;
    sort-threads) printf '%s\n' "sort --parallel=4 -S 64M $W/lines.txt | md5sum" ;;
    python-threads) printf '%s\n' "python3 $W/threads.py" ;;
    make-jobs) printf '%s\n' "cd $W && rm -rf mk && mkdir mk && cd mk && { printf 'all:'; for i in \$(seq 1 32); do printf ' t%d' \$i; done; printf '\n'; for i in \$(seq 1 32); do printf 't%d:\n\t@seq 1 %d | md5sum >t%d.out\n' \$i \$((i * 2000)) \$i; done; } >Makefile && make -s -j4 && cat \$(ls t*.out | sort) | md5sum" ;;
    esac
}
cases=${SOAK_CASES:-git-repack xz-threads sort-threads python-threads make-jobs}
fails=0
total=0
for c in $cases; do
    want=$(timeout 600 $T run --mode full "$B" -c "$(case_cmd $c)" 2>&1)
    for s in default fresh block; do
        case $s in
        default) env= ;;
        fresh) env="TSO_VIEWS_PROFILE=none" ;;
        block) env="FEX_MULTIBLOCK=0" ;;
        esac
        bad=0
        i=0
        start=$(date +%s)
        while [ $i -lt $rounds ]; do
            i=$((i + 1))
            got=$(env $env timeout 600 $T run "$B" -c "$(case_cmd $c)" 2>&1)
            st=$?
            if [ $st != 0 ] || [ "$got" != "$want" ]; then
                bad=$((bad + 1))
                [ $bad = 1 ] && echo "$got" | tail -n 3 | sed "s/^/        $c, $s, run $i, exit $st: /"
            fi
        done
        total=$((total + rounds))
        fails=$((fails + bad))
        printf '%-6s %-15s %-8s %d of %d runs right, %d s\n' "$([ $bad = 0 ] && echo ok || echo FAIL)" "$c" "$s" \
            $((rounds - bad)) $rounds $(( $(date +%s) - start ))
    done
done
echo "soak: $((total - fails)) of $total runs right"
[ $fails = 0 ]

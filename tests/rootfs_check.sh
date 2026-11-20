#!/bin/sh
# Everyday programs of an x86-64 root file system under tso-arm, each output compared with FEX's full ordering:
# shells with pipes, command substitution, traps and job control, coreutils, compression, perl, python with
# subprocess and multiprocessing (fork without exec from a process with threads), x87 arithmetic, git packing with
# threads, make with parallel jobs, rsync. Needs the root
# file system `tso-arm rootfs` fetches (or ROOTFS=directory).
#   tests/rootfs_check.sh          exit status 1 if an output differs or a command fails under tso-arm
set -u
cd "$(dirname "$0")/.."
T=bin/tso-arm
if [ -z "${ROOTFS:-}" ]; then
    ROOTFS=$(ls -d "$HOME"/.local/share/fex-emu/RootFS/*/ 2>/dev/null | head -n 1)
fi
[ -n "$ROOTFS" ] && [ -x "$ROOTFS/usr/bin/bash" ] || {
    echo "no x86-64 root file system: 'tso-arm rootfs' fetches one (or set ROOTFS)"
    exit 2
}
export LC_ALL=C
B=${ROOTFS%/}/usr/bin/bash
fails=0
n=0

check() {
    name=$1
    shift
    n=$((n + 1))
    want=$(timeout 300 $T run --mode full "$B" -c "$*" 2>&1)
    wst=$?
    got=$(timeout 300 $T run "$B" -c "$*" 2>&1)
    gst=$?
    if [ "$got" = "$want" ] && [ $gst = $wst ]; then
        printf 'ok    %-22s %s\n' "$name" "$(echo "$got" | tail -n 1 | cut -c1-70)"
    else
        fails=$((fails + 1))
        printf 'FAIL  %-22s exit %s against %s\n' "$name" $gst $wst
        echo "$got" | tail -n 4 | sed 's/^/        tso:  /'
        echo "$want" | tail -n 4 | sed 's/^/        full: /'
    fi
}

check substitution 'x=$(echo sub); y=$(seq 1 3 | tr "\n" " "); echo "$x $y"'
check pipeline 'seq 1 200000 | sort -rn | head -n 3 | tr "\n" " "; echo'
check loop-of-forks 'n=0; for i in $(seq 1 100); do n=$((n + $(echo 1))); done; echo $n'
check subshells '(echo a; (echo b; (echo c))) | tr "\n" " "; echo'
check trap 'trap "echo trapped" USR1; kill -USR1 $$; echo after'
check job-control '(sleep 0.2; echo late) & echo early; wait; echo done'
check timeout 'timeout 0.3 sleep 5; echo "status $?"'
check background-reap 'for i in 1 2 3 4 5; do (exit $i) & done; wait; echo reaped'
check printf-long-double 'printf "%.18Lf %.10Le\n" 1.1 3.14159265358979323846'
check awk 'seq 1 100000 | awk "{s += \$1; q += \$1 * \$1} END {printf \"%d %.6e\n\", s, q}"'
check sed-grep 'seq 1 50000 | sed -n "s/7\$/seven/p" | grep -c seven'
check md5-sha 'seq 1 300000 | md5sum; seq 1 300000 | sha256sum'
check gzip 'seq 1 300000 | gzip -6 | gunzip | md5sum; seq 1 300000 | gzip -9 | wc -c'
check xz 'seq 1 200000 | xz -T2 | xz -d | md5sum'
check tar 'cd /usr/share/doc && tar -cf - bash coreutils 2>/dev/null | md5sum'
check find-xargs 'find /usr/share/doc -maxdepth 2 -name "copyright" | sort | head -n 200 | xargs cat | md5sum'
check factor 'factor 1234567890123 600851475143 18446744073709551557'
check date 'date -u -d @1700000000 "+%F %T %s"'
check perl 'perl -e "my %h; \$h{\$_} = \$_ * 2 for 1 .. 200000; my \$s = 0; \$s += \$_ for values %h; print scalar(keys %h), \" \$s\n\"; printf \"%.15g\n\", atan2(1, 1) * 4"'
check perl-fork 'perl -e "for (1 .. 5) { my \$p = fork; if (!\$p) { exit \$_ } waitpid(\$p, 0); print \$? >> 8 } print qq(\n)"'
check python 'python3 -c "import hashlib, json, math; print(hashlib.sha256(json.dumps([math.factorial(i) % 997 for i in range(3000)]).encode()).hexdigest())"'
check python-subprocess 'python3 -c "import subprocess; print(subprocess.run([\"seq\", \"1\", \"5\"], capture_output=True, text=True).stdout.split())"'
check python-fork-pool 'python3 -c "
import multiprocessing as mp
def sq(x): return x * x
if __name__ == \"__main__\":
    mp.set_start_method(\"fork\")
    with mp.Pool(4) as p: print(sum(p.map(sq, range(20000))))
"'
check python-threads-fork 'python3 -W ignore -c "
import os, threading
total = [0]
def work():
    for i in range(200000): total[0] += 1
ts = [threading.Thread(target=work) for _ in range(3)]
for t in ts: t.start()
pid = os.fork()
if pid == 0:
    os._exit(7)
_, st = os.waitpid(pid, 0)
for t in ts: t.join()
print(os.WEXITSTATUS(st))
"'
check python-signal 'python3 -c "
import signal, os, time
got = []
signal.signal(signal.SIGUSR1, lambda s, f: got.append(s))
signal.signal(signal.SIGALRM, lambda s, f: got.append(s))
os.kill(os.getpid(), signal.SIGUSR1)
signal.setitimer(signal.ITIMER_REAL, 0.05)
time.sleep(0.2)
print(got)
"'

# git: a repository of 60 commits made with fast-import, packed anew with 4 threads searching deltas at once
git_script=$(cat <<'EOF'
d=$(mktemp -d) && cd "$d" || exit 1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main repo && cd repo || exit 1
awk 'BEGIN {
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
}' | git fast-import --quiet || exit 1
git repack -a -d -f -q --threads=4 --window=20 || exit 1
git fsck --strict --no-progress && echo "fsck ok"
git count-objects -v | sed -n "s/^in-pack: /objects /p"
git rev-list --objects --all | sort | md5sum
cd / && rm -rf "$d"
EOF
)
check git-repack-threads "$git_script"
# make with 4 jobs at once: 40 recipes, each a pipeline of its own
make_script=$(cat <<'EOF'
d=$(mktemp -d) && cd "$d" || exit 1
{
    printf "all:"
    for i in $(seq 1 40); do printf " t%d" $i; done
    printf "\n"
    for i in $(seq 1 40); do printf "t%d:\n\t@seq 1 %d | md5sum >t%d.out\n" $i $((i * 3000)) $i; done
} >Makefile
make -s -j4 && cat $(ls t*.out | sort) | md5sum
cd / && rm -rf "$d"
EOF
)
check make-parallel "$make_script"
check rsync 'd=$(mktemp -d); rsync -a /usr/share/doc/ "$d/doc/" && cd "$d/doc" && find . -type f | sort | xargs md5sum | md5sum; cd / && rm -rf "$d"'

echo "rootfs_check: $((n - fails)) of $n the same as FEX's full ordering"
[ $fails = 0 ]

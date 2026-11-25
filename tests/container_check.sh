#!/bin/sh
# x86-64 containers on this Arm machine, as a user runs them once 'tso-arm binfmt register' has registered the
# statically linked FEX: the container's own programs and the test programs of tests/ci.sh mounted in, with x86 order
# kept, without any of the host's files in the container. Needs docker (or podman as docker) and the registration.
#   tests/container_check.sh     IMAGE (default ubuntu:24.04)
# Exit status 1 if something does not run or a message arrives wrong.
cd "$(dirname "$0")/.."
img=${IMAGE:-ubuntu:24.04}
B=$PWD/build/ci
fail=0
ok() { echo "ok:   $*"; }
bad() {
    echo "FAIL: $*"
    fail=1
}
grep -qs '^flags:.*F' /proc/sys/fs/binfmt_misc/tso-arm || {
    echo "FAIL: x86-64 programs are not registered for containers ('sudo tso-arm binfmt register' with a statically linked FEX)"
    exit 1
}
run() { timeout 900 docker run --rm --platform linux/amd64 -v "$B:/ci:ro" "$@" 2>&1; }
docker pull -q --platform linux/amd64 "$img" >/dev/null || {
    echo "FAIL: docker pull $img"
    exit 1
}

out=$(run "$img" uname -m)
[ "$out" = x86_64 ] && ok "$img: uname -m: $out" || bad "$img: uname -m: $out"

# a statically linked program, and one linked against the container's own C library
for p in "threads 8" "threads-dyn 8"; do
    out=$(run "$img" /ci/$p | tail -n 1)
    echo "$out" | grep -q 'wrong 0' && ok "$p: $out" || bad "$p: $out"
done
out=$(run -e TSO_ARM_MODE=unordered "$img" /ci/threads 8 | tail -n 1)
echo "      without ordering, for comparison: $out"

# fork in a program with threads, signals
out=$(run "$img" /ci/forksnap 30 | tail -n 1)
echo "$out" | grep -q ', 0 children saw' && ok "$out" || bad "forksnap: $out"
out=$(run "$img" /ci/signals | tail -n 1)
echo "$out" | grep -q 'all handled' && ok "$out" || bad "signals: $out"

# the distribution's own tools: its package manager fetches and installs Python, which then runs threads
s=$(date +%s)
out=$(run "$img" sh -c 'apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends python3-minimal >/dev/null &&
python3 -c "
import threading
n = [0]
lock = threading.Lock()
def work():
    for _ in range(100000):
        with lock:
            n[0] += 1
t = [threading.Thread(target=work) for _ in range(4)]
[x.start() for x in t]
[x.join() for x in t]
print(\"python threads:\", n[0])
"' | tail -n 1)
[ "$out" = "python threads: 400000" ] && ok "apt-get install python3, then $out ($(($(date +%s) - s)) s)" ||
    bad "apt-get and python3: $out"

# a 32-bit program (FEX orders every access of it itself)
out=$(run "$img" /ci/threads32 8 | tail -n 1)
echo "$out" | grep -q 'wrong 0' && ok "32-bit threads 8: $out" || bad "32-bit threads 8: $out"
exit $fail

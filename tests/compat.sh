#!/bin/sh
# Programs of an x86-64 Linux distribution under tso-arm, from the root file system tools/compat_rootfs.sh packs:
# multi-threaded work with a fixed output (sort, 7-Zip, Python threads, ffmpeg with x264, Node worker threads), each
# with x86 order kept (tso-arm), with FEX's full TSO and without ordering; outputs compared, wall times. And message
# passing in JavaScript: a worker thread writes data and then a flag into a SharedArrayBuffer with plain stores, the
# main thread reads the flag and then the data; only x86's order keeps it from seeing the flag before the data.
#   tests/compat.sh ROOTFS.tar.zst|DIR      on the Arm machine (unpacks a tar to build/compat-rootfs)
#   tests/compat.sh --here                  on the x86-64 machine itself, twice: are the outputs fixed?
# ROUNDS (default 3): best wall time of that many runs per program and mode.
set -e
cd "$(dirname "$0")/.."
R=$PWD
T=$R/bin/tso-arm
W=${COMPAT_DIR:-$R/build/compat}
rounds=${ROUNDS:-3}
mkdir -p $W
if [ "$1" = --here ]; then
    root=""
    modes="here1 here2"
else
    [ $# = 1 ] || { echo "usage: tests/compat.sh ROOTFS.tar.zst|DIR | --here" >&2; exit 1; }
    if [ -d "$1" ]; then
        root=$(readlink -f "$1")
    else
        root=$R/build/compat-rootfs
        stamp="$(stat -c %s-%Y "$1")"
        if [ "$(cat $root.stamp 2>/dev/null)" != "$stamp" ]; then
            rm -rf $root && mkdir -p $root
            zstd -dc "$1" | tar -C $root -xf -
            echo "$stamp" >$root.stamp
        fi
    fi
    export FEX_ROOTFS=$root
    modes="tso full unordered"
fi
sevenzip=$(sed -n 's/^exec "\{0,1\}\(\/[^" ]*\).*/\1/p' ${root:-}/usr/bin/7z 2>/dev/null || true)
[ -n "$sevenzip" ] || sevenzip=/usr/bin/7z

# inputs, made the same way on any machine
[ -f $W/lines.txt ] || awk 'BEGIN { s = 12345; for (i = 0; i < 2000000; i++) { s = (s * 1103515245 + 12345) % 2147483648
    printf "%08x %d line %d\n", s, s % 1000, i } }' >$W/lines.txt
[ -f $W/corpus.bin ] || { cat $W/lines.txt; head -c 33554432 $W/lines.txt | od -An -tx1; } 2>/dev/null |
    head -c 67108864 >$W/corpus.bin
cat >$W/threads.py <<'EOF'
import hashlib, queue, threading
data = bytes(range(256)) * 16384
out = [None] * 16
def work(i):
    h = hashlib.sha256()
    for k in range(12):
        h.update(data[i * 997 + k:] + data[:i * 997 + k])
    out[i] = h.hexdigest()
ts = [threading.Thread(target=work, args=(i,)) for i in range(16)]
for t in ts: t.start()
for t in ts: t.join()
q, total = queue.Queue(maxsize=64), [0]
def produce():
    for i in range(200000): q.put(i)
    q.put(None)
def consume():
    while (v := q.get()) is not None: total[0] += v * v % 7919
p, c = threading.Thread(target=produce), threading.Thread(target=consume)
p.start(); c.start(); p.join(); c.join()
print(hashlib.sha256("".join(out).encode()).hexdigest(), total[0])
EOF
cat >$W/workers.js <<'EOF'
// worker threads: a fixed sum over shared memory, then message passing without Atomics on the writer's side
const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');
if (isMainThread) {
  const n = 4, sab = new SharedArrayBuffer(4 * 1024 * 1024), a = new Int32Array(sab);
  let done = 0;
  for (let w = 0; w < n; w++) {
    new Worker(__filename, { workerData: { sab, w, n, kind: 'sum' } }).on('message', () => {
      if (++done < n) return;
      let s = 0;
      for (let i = 0; i < a.length; i++) s = (s + a[i] * (i % 13)) | 0;
      const mp = new SharedArrayBuffer(4096), m = new Int32Array(mp), N = 3000000;
      const wk = new Worker(__filename, { workerData: { sab: mp, N, kind: 'mp' } });
      let wrong = 0, seen = 0;
      while (seen < N) {
        const f = Atomics.load(m, 256);   // the flag (a plain load on x86-64)
        const d = m[0];                    // then the data
        if (d < f) wrong++;
        seen = f;
      }
      wk.terminate();
      console.log('sum', s, 'mp-wrong', wrong);
    });
  }
} else {
  const a = new Int32Array(workerData.sab);
  if (workerData.kind === 'sum') {
    const { w, n } = workerData;
    for (let r = 0; r < 20; r++)
      for (let i = w; i < a.length; i += n) a[i] = (a[i] + i * 31 + r) | 0;
    parentPort.postMessage(0);
  } else {
    for (let i = 1; i <= workerData.N; i++) { a[0] = i; a[256] = i; }  // data, then flag: plain stores
  }
}
EOF

prefix() { # mode -> what runs the program in that mode
    case $1 in
    here1 | here2) echo "" ;;
    tso) echo "$T run" ;;
    # FEX's own settings in FEX's columns (tso-arm compiles smaller units, bin/tso-arm)
    full) echo "env FEX_MAXINST=5000 $T run --mode full" ;;
    unordered) echo "env FEX_MAXINST=5000 $T run --mode unordered" ;;
    esac
}
case_cmd() { # name -> command (program from the root file system, arguments)
    case $1 in
    sort) echo "${root}/usr/bin/sort --parallel=4 -S 256M $W/lines.txt" ;;
    7zip) echo "$root$sevenzip a -txz -mmt=4 -mx=3 -si -so -bd -bso0 -bse0 x <$W/corpus.bin" ;; # -mx=3: 4 blocks at once
    python) echo "${root}/usr/bin/python3 $W/threads.py" ;;
    ffmpeg) echo "${root}/usr/bin/ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=4 -c:v libx264 -preset fast -threads 4 -f md5 -" ;;
    node) echo "${root}/usr/bin/node $W/workers.js" ;;
    esac
}
cases=${CASES:-sort 7zip python ffmpeg node}
{
    echo "| program | $(echo $modes | sed 's/ / | /g') | output |"
    echo "|---$(for m in $modes; do printf '|---'; done)|---|"
    for c in $cases; do
        row="| $c |"
        sums=""
        for m in $modes; do
            best=""
            for i in $(seq $rounds); do
                s=$(date +%s%N)
                sh -c "$(prefix $m) $(case_cmd $c)" >$W/out-$c-$m 2>$W/err-$c-$m </dev/null || true
                e=$(date +%s%N)
                t=$(( (e - s) / 1000000 ))
                [ -z "$best" ] || [ $t -lt $best ] && best=$t
            done
            case $c in
            node) sum=$(cat $W/out-$c-$m | tr ' ' '_') ;;
            *) sum=$(md5sum <$W/out-$c-$m | cut -c1-8) ;;
            esac
            [ -s $W/out-$c-$m ] || sum="no-output($(head -c 80 $W/err-$c-$m | tr '\n|' '  '))"
            sums="$sums $sum"
            row="$row $best ms |"
        done
        first=$(echo $sums | cut -d' ' -f1)
        same=yes
        for s in $sums; do
            case $c in
            node) [ "${s%%_mp-wrong*}" = "${first%%_mp-wrong*}" ] || same=no ;;
            *) [ "$s" = "$first" ] || same=no ;;
            esac
        done
        echo "$row $( [ $same = yes ] && echo same || echo "DIFFERENT:$sums") |"
        if [ $c = node ]; then
            echo "| node message passing, wrong |$(for s in $sums; do printf ' %s |' "${s##*mp-wrong_}"; done) |"
        fi
    done
} >$W/compat.md
cat $W/compat.md
# failed: an output that differs, or a message seen before its data with x86 order kept (tso-arm, FEX full TSO)
! grep -q DIFFERENT $W/compat.md || { echo "compat: outputs differ"; exit 1; }
if [ "$1" != --here ]; then
    w=$(sed -n 's/^| node message passing, wrong | \([0-9]*\) | \([0-9]*\) |.*/\1 \2/p' $W/compat.md)
    [ -z "$w" ] || [ "$w" = "0 0" ] || { echo "compat: messages seen before their data with x86 order kept: $w"; exit 1; }
fi
echo "compat: all outputs the same"
# COMPAT_STATS=1: one more run of each with x86 order kept and the page protocol's statistics (after the rounds above,
# so with the profile they left)
if [ -n "$COMPAT_STATS" ] && [ "$1" != --here ]; then
    for c in $cases; do
        s=$(date +%s%N)
        sh -c "$T run --stats $(case_cmd $c)" >/dev/null 2>$W/stats-$c </dev/null || true
        e=$(date +%s%N)
        echo "$c: $(( (e - s) / 1000000 )) ms"
        grep '^tso-arm: \(handled\|claims\)' $W/stats-$c | sed 's/^/    /'
    done | tee $W/stats.txt
fi

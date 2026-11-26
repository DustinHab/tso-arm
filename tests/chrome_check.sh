#!/bin/sh
# Chromium under tso-arm: Google's headless shell (Chrome for Testing, its stable channel, from Google's storage)
# renders a page whose script runs V8's compilers on a loop, calls WebAssembly and writes the results into the page.
# Under the page protocol in its first run (no profile: Chromium's allocator reserves 32 GB at once, more than the
# views' window holds) and in two runs with the profile, and under FEX's full ordering. The browser, its zygote,
# renderer, GPU and network processes all have to come up for the page to come back. (WebAssembly's trap, an access
# past its memory that V8 catches with its handler of SIGSEGV, stops the renderer under FEX in every mode: notes
# section 64.)
#   tests/chrome_check.sh [DIR]     DIR: where the headless shell is kept (default build/chrome)
# Exit status 1 if a run did not return the page as expected.
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
T=$R/bin/tso-arm
D=${1:-$R/build/chrome}
mkdir -p "$D"
D=$(cd "$D" && pwd)
S=$D/chrome-headless-shell-linux64/chrome-headless-shell

if [ ! -x "$S" ]; then
    curl -fsSL --retry 2 -o "$D/versions.json" \
        https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json
    url=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print([x["url"] for x in d["channels"]["Stable"]["downloads"]["chrome-headless-shell"] if x["platform"] == "linux64"][0])' "$D/versions.json")
    case $url in
    https://storage.googleapis.com/chrome-for-testing-public/*) ;;
    *)
        echo "chrome_check: unexpected download address $url"
        exit 1
        ;;
    esac
    echo "chrome_check: fetching $url"
    curl -fsSL --retry 2 -o "$D/shell.zip" "$url"
    rm -rf "$D/chrome-headless-shell-linux64"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$D/shell.zip" "$D"
    # (the zip's file modes are not kept: the shell is the one program in it)
    chmod +x "$S"
    rm -f "$D/shell.zip"
fi
echo "chrome_check: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channels"]["Stable"]["version"])' "$D/versions.json" 2>/dev/null || echo "headless shell") in $D"

# primes below 200,000 (17,984), and a WebAssembly function loading from its one page of memory
cat >"$D/page.html" <<'EOF'
<html><body><p id=out>not run</p><script>
let c = 0;
for (let n = 2; n < 200000; n++) { let p = 1; for (let d = 2; d * d <= n; d++) { if (n % d == 0) { p = 0; break; } } c += p; }
const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,3,2,1,0,5,3,1,0,1,7,6,1,2,108,100,0,0,10,9,1,7,0,32,0,40,2,0,11]);
const ld = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.ld;
document.getElementById('out').textContent = 'script ran ' + (6 * 7) + ', primes ' + c + ', wasm ' + ld(0) + ' ' + ld(65532);
</script></body></html>
EOF
want='script ran 42, primes 17984, wasm 0 0'

fail=0
n=0
run() {
    what=$1
    shift
    n=$((n + 1))
    rm -rf "$D/profile-$n"
    s=$(date +%s.%N)
    st=0
    env "$@" timeout 300 "$T" run "$S" --no-sandbox --user-data-dir="$D/profile-$n" --dump-dom "file://$D/page.html" \
        >"$D/out-$n.html" 2>"$D/err-$n.txt" || st=$?
    e=$(date +%s.%N)
    secs=$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.1f", e - s }')
    if grep -q "$want" "$D/out-$n.html"; then
        echo "  ok    $what: the page in $secs s"
    else
        echo "  FAIL  $what: exit status $st after $secs s, page: $(grep -o '<p id="out">[^<]*' "$D/out-$n.html" | head -n 1)"
        grep -v '^$' "$D/err-$n.txt" | tail -n 8 | sed 's/^/        /'
        fail=1
    fi
    rm -rf "$D/profile-$n"
}

p=$D/views-profile
rm -f "$p"
run "page protocol, first run (no profile)" TSO_ARM_MODE=tso TSO_VIEWS_PROFILE=none
run "page protocol, profile learned" TSO_ARM_MODE=tso TSO_VIEWS_PROFILE="$p"
run "page protocol, with the profile" TSO_ARM_MODE=tso TSO_VIEWS_PROFILE="$p"
run "FEX's full ordering" TSO_ARM_MODE=full
rm -f "$p"

# from inside the root file system, where 'tso-arm app' installs programs: Chromium starts its zygote, renderers and
# services through /proc/self/exe, which FEX named there without the root file system's own path, and the execve
# failed with ENOEXEC (Microsoft Edge's network service ran as a shell script)
rfs=$("$T" app rootfs 2>/dev/null) || rfs=
if [ -n "$rfs" ] && [ -w "$rfs/opt" ]; then
    rm -rf "$rfs/opt/tso-arm-check"
    mkdir -p "$rfs/opt/tso-arm-check"
    cp -a "$D/chrome-headless-shell-linux64" "$rfs/opt/tso-arm-check/"
    outside=$S
    S=$rfs/opt/tso-arm-check/chrome-headless-shell-linux64/chrome-headless-shell
    run "from inside the root file system, full ordering" TSO_ARM_MODE=full
    S=$outside
    rm -rf "$rfs/opt/tso-arm-check"
else
    echo "  (no writable root file system: not run from inside one)"
fi

# for the record, not required (notes section 64): a WebAssembly access past its memory, which V8 catches with its
# handler of SIGSEGV and turns into a RuntimeError
cat >"$D/trap.html" <<'EOF'
<html><body><p id=out>not run</p><script>
const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,6,1,96,1,127,1,127,3,2,1,0,5,3,1,0,1,7,6,1,2,108,100,0,0,10,9,1,7,0,32,0,40,2,0,11]);
const ld = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.ld;
let w; try { ld(65536 * 4); w = 'no trap'; } catch (e) { w = (e instanceof WebAssembly.RuntimeError) ? 'trap' : 'other: ' + e; }
document.getElementById('out').textContent = 'wasm ' + w;
</script></body></html>
EOF
rm -rf "$D/profile-trap"
st=0
TSO_ARM_MODE=full timeout 60 "$T" run "$S" --no-sandbox --user-data-dir="$D/profile-trap" --dump-dom "file://$D/trap.html" \
    >"$D/trap.out" 2>"$D/trap.err" || st=$?
if grep -q 'wasm trap' "$D/trap.out"; then
    echo "  (for the record) WebAssembly's trap under full ordering: caught"
else
    echo "  (for the record) WebAssembly's trap under full ordering: not caught (exit status $st; $(grep -m1 'Received signal' "$D/trap.err"))"
fi
rm -rf "$D/profile-trap"
exit $fail

#!/bin/sh
# Test machine: the session shown in the README, as a user would see it: pigz as distributions build it (PIE, linked
# dynamically), run, learned, run again, with the page protocol's statistics.
#   tools/readme_demo.sh
cd "$(dirname "$0")/.."
export FEX_ROOTFS=$PWD/build/rootfs-x86
cp build/x86pie/pigz /tmp/pigz
cp build/corpus.tar /tmp/data.tar
cd /tmp
T=~/tso-arm/bin/tso-arm
$T forget ./pigz >/dev/null
echo '$ file pigz'
file -b ./pigz | cut -c1-90
echo '$ time tso-arm run ./pigz -c data.tar > data.tar.gz'
s=$(date +%s%N); $T run ./pigz -c data.tar >/tmp/data.tar.gz; e=$(date +%s%N); echo "  $(( (e - s) / 1000000 )) ms"
echo '$ tso-arm learn ./pigz -c data.tar'
$T learn ./pigz -c data.tar 2>&1
echo '$ time tso-arm run ./pigz -c data.tar > data.tar.gz'
s=$(date +%s%N); $T run ./pigz -c data.tar >/tmp/data.tar.gz; e=$(date +%s%N); echo "  $(( (e - s) / 1000000 )) ms"
echo '$ tso-arm run --stats ./pigz -c data.tar > data.tar.gz'
$T run --stats ./pigz -c data.tar 2>&1 >/tmp/data.tar.gz | head -n 20
echo '$ tso-arm status ./pigz'
$T status ./pigz
rm -f /tmp/pigz /tmp/data.tar /tmp/data.tar.gz

#!/bin/sh
# Test machine: tso-arm on other Arm cores, in a full system emulation (QEMU, TCG): Debian 13's arm64 cloud image
# (~/vm, from cloud.debian.org), one fresh overlay per core model, cloud-init fetching the payload from a small HTTP
# server on the host and running tests/vm_guest.sh; the TSOTEST lines of the console end up in out/vm-MODEL.log.
# Correctness only: emulated cores have no real timing.
#   tests/vm_run.sh MODEL...      (e.g. cortex-a53 cortex-a72 neoverse-v1 cortex-a710)
#   GUEST=vm_diag.sh: another script for the guest; REBUILD=1: the payload made anew
cd "$(dirname "$0")/.."
R=$PWD
V=$HOME/vm
S=/tmp/vmseed
mkdir -p $S/payload out
# the payload: FEX for Armv8.0, the tests, pigz's library for both kinds of core, a small input
if [ ! -f $S/payload.tar.gz ] || [ "${REBUILD:-}" = 1 ]; then
    rm -rf $S/payload/*
    cp -a $HOME/opt/fex-generic $S/payload/fex
    cp -a $HOME/opt/fex $S/payload/fex-up # upstream FEX (built for the A76: only for cores that have its features)
    cp build/threads-x86 build/mp-x86 build/x86/pigz $S/payload/
    cp tests/${GUEST:-vm_guest.sh} $S/payload/vm_guest.sh
    head -c 1000000 build/corpus.tar >$S/payload/in.tar
    build/arm64/pigz -n -p 4 -c $S/payload/in.tar | md5sum | cut -c1-8 >$S/payload/want.md5
    AOT_NORCPC=1 sh aot/pigz.sh >/dev/null && cp out/aot/pigz.so $S/payload/pigz-v80.so
    sh aot/pigz.sh >/dev/null && cp out/aot/pigz.so $S/payload/pigz-rcpc.so
    tar -czf $S/payload.tar.gz -C $S/payload .
fi
cat >$S/user-data <<'EOF'
#cloud-config
runcmd:
  - mkdir -p /root/t
  - python3 -c "import urllib.request; open('/root/t.tgz','wb').write(urllib.request.urlopen('http://10.0.2.2:8000/payload.tar.gz').read())"
  - tar -xzf /root/t.tgz -C /root/t
  - sh /root/t/vm_guest.sh
EOF
: >$S/vendor-data
python3 -m http.server 8000 --bind 0.0.0.0 --directory $S >/dev/null 2>&1 &
http=$!
trap 'kill $http 2>/dev/null' EXIT
for m in "$@"; do
    printf 'instance-id: tso-%s-%s\nlocal-hostname: tso-vm\n' $m $(date +%s) >$S/meta-data
    rm -f $V/run-$m.qcow2
    qemu-img create -q -f qcow2 -b $V/debian-13-genericcloud-arm64.qcow2 -F qcow2 $V/run-$m.qcow2 8G
    log=out/vm-$m.log
    s=$(date +%s)
    timeout ${LIMIT:-7200} qemu-system-aarch64 -M virt -accel tcg,thread=multi -cpu $m -smp 4 -m 6144 \
        -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        -drive if=virtio,file=$V/run-$m.qcow2,format=qcow2 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -smbios type=1,serial=ds=nocloud\;s=http://10.0.2.2:8000/ \
        -display none -serial file:$log -monitor none
    e=$(date +%s)
    echo "== $m ($(( (e - s) / 60 )) min)"
    grep -a 'TSOTEST' $log | sed 's/^.*TSOTEST /  /' | tr -d '\r'
    rm -f $V/run-$m.qcow2
done

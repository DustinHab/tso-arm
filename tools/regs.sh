#!/bin/sh
# Test machine: pc, lr and sp of every thread of a running process (gdb attaches briefly), with the mapping the pc
# lies in.
#   tools/regs.sh PID
p=$1
cat >/tmp/regs.gdb <<'EOF'
set pagination off
thread apply all info registers pc lr sp
EOF
sudo gdb -p $p -batch -x /tmp/regs.gdb 2>/dev/null | grep -E '^Thread|^pc|^lr|^sp'
echo "mappings:"
sudo cat /proc/$p/maps | grep -E 'xz.so|pigz.so|zstd.so|r-xp' | head -n 20

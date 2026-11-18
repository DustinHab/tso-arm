#!/bin/sh
# Test machine: for the log of tests/zstd_threads_log.sh (/tmp/zl.err): the patch behind the first stub, the guest
# mappings that cover the first unhandled fault address, and the slot-0 lines around it.
#   tests/zstd_fault_range.sh
grep 'stub 0x[0-9a-f]*000)' /tmp/zl.err | head -n 3
addr=$(grep -o 'fault R at 0x[0-9a-f]* slot 0' /tmp/zl.err | head -n 1 | awk '{ print $4 }')
echo "first unhandled fault: $addr"
python3 - "$addr" <<'EOF'
import sys, re
a = int(sys.argv[1], 16) & ((1 << 34) - 1)
print(f"guest address {a:#x}")
for n, l in enumerate(open("/tmp/zl.err"), 1):
    m = re.search(r"tso-arm: (mmap|munmap|mremap|mprotect) (0x[0-9a-f]+|0)\+(0x[0-9a-f]+)", l)
    if m:
        s, ln = int(m.group(2), 16), int(m.group(3), 16)
        if s <= a < s + ln or (m.group(1) == "mmap" and s == 0):
            pass
        if s <= a < s + ln:
            print(f"  line {n}: {l.strip()[:150]}")
    m = re.search(r"range (0x[0-9a-f]+)-(0x[0-9a-f]+) into the views of slot (\d+)", l)
    if m and int(m.group(1), 16) <= a < int(m.group(2), 16):
        print(f"  line {n}: {l.strip()[:150]}")
EOF
echo "== the handler's view of it"
grep -n '(view ' /tmp/zl.err | head -n 3
echo "== mappings made by slot 0 (threads without a slot)"
grep -n 'mmap -> .*(slot 0)' /tmp/zl.err | head -n 5
grep -n 'mmap -> ' /tmp/zl.err | python3 -c '
import sys
a = int(sys.argv[1], 16) & ((1 << 34) - 1)
for l in sys.stdin:
    pass
' "$addr"
grep -n -i 'no view slot\|full ordering' /tmp/zl.err | head -n 3

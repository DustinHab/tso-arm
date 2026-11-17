#!/bin/sh
# Test machine: the AArch64 encodings the site patcher in FEX writes (Thunks.cpp, AOT::Patch), from the assembler.
#   aot/encodings.sh
cat >/tmp/enc.s <<'EOF'
orr x5, x5, #0x4000000000
and x5, x5, #0xffffffbfffffffff
tbnz x5, #38, .+20
dmb ishld
dmb ish
b .+16
EOF
as -o /tmp/enc.o /tmp/enc.s && objdump -d /tmp/enc.o | grep -E '^ +[0-9a-f]+:'

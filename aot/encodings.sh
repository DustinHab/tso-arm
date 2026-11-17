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
add x2, x1, #0x10
add x2, x1, #0x5, lsl #12
sub x2, x1, #0x10
add x2, x1, x13
add x2, x1, x13, lsl #3
add x2, x1, w13, uxtw #2
add x2, x1, w13, sxtw
tst x2, #1
tst x2, #3
tst x2, #7
b.ne .+12
ldapr x2, [x2]
ldapr w2, [x2]
ldaprh w2, [x2]
ldaprb w2, [x2]
sxtw x2, w2
sxth x2, w2
sxtb x2, w2
sxth w2, w2
sxtb w2, w2
EOF
as -march=armv8.2-a+rcpc -o /tmp/enc.o /tmp/enc.s && objdump -d /tmp/enc.o | grep -E '^ +[0-9a-f]+:'

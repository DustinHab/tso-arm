# tso-arm

Fast and correct emulation of the x86 memory model (TSO) on Arm processors without a hardware TSO mode.

x86 guarantees that loads are not reordered with other loads, stores are not reordered with other stores, and loads
are not reordered with later stores. Arm guarantees none of this for plain loads and stores. An x86-to-Arm binary
translator therefore maps every guest memory access to an ordered Arm access (`ldapr`/`stlr`, or plain accesses plus
`dmb` barriers). FEX reports this as the largest single cost of its x86 emulation; Apple avoids it with a TSO mode
in its cores that other Arm processors do not have.

This repository measures that cost on real hardware and works on removing it where it cannot be observed, without
giving up correctness.

## Layout

| Path | Contents |
|---|---|
| `bench/` | microbenchmarks for the cost of ordered accesses on the host (AArch64) |
| `litmus/` | x86-64 litmus tests that detect reordering, run natively and under translators |
| `tools/` | sync and run scripts for the test machine |
| `docs/NOTES.md` | measurements, decisions and findings in order |

## Test machine

Raspberry Pi 5: Cortex-A76 (4 cores, 2.4 GHz), 16 GB, Debian 13, kernel 6.18 with 4 KB pages and 39-bit virtual
addresses. The A76 has LSE atomics and FEAT_LRCPC (`ldapr`), but not FEAT_LRCPC2 (`ldapur`), FEAT_LRCPC3 or FEAT_LSE2.

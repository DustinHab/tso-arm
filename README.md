# tso-arm

Fast and correct emulation of the x86 memory model (TSO) on Arm processors without a hardware TSO mode.

x86 guarantees that loads are not reordered with other loads, stores are not reordered with other stores, and loads
are not reordered with later stores. Arm guarantees none of this for plain loads and stores. An x86-to-Arm binary
translator therefore maps every guest memory access to an ordered Arm access (`ldapr`/`stlr`, or plain accesses plus
`dmb` barriers). FEX reports this as the largest single cost of its x86 emulation; Apple avoids it with a TSO mode
in its cores that other Arm processors do not have.

This repository measures that cost on real hardware and works on removing it where it cannot be observed, without
giving up correctness.

## Efficiency

x86-64 builds of zstd, pigz and xz under FEX, against native Arm builds of the same sources with the same compiler
options (`bench/build_native.sh`, `bench/efficiency.sh`). The protocol is the page protocol of `fex/patches/`;
"x86 memory order kept" says whether the configuration is correct for multithreaded x86 programs. Updated with every
change to the mechanism (`tools/readme_efficiency.py`).

<!-- efficiency:begin -->
Measured 2026-11-17T18:56, Raspberry Pi 5 at 1.8 GHz, 4 threads, best of the rounds, wall time.

| Configuration | x86 memory order kept | pigz | xz | zstd | geometric mean |
|---|---|---|---|---|---|
| native Arm | - | 1.01 s, 100 % | 1.07 s, 100 % | 0.49 s, 100 % | 100 % |
| FEX, TSO off | no | 1.14 s, 89 % | 1.34 s, 80 % | 0.58 s, 84 % | 84 % |
| tso-arm build, TSO off | no | 1.14 s, 89 % | 1.33 s, 80 % | 0.58 s, 84 % | 84 % |
| FEX default | no | 1.58 s, 64 % | 1.53 s, 70 % | 0.69 s, 71 % | 68 % |
| FEX full TSO | yes, except stack accesses through RSP | 1.65 s, 61 % | 1.54 s, 69 % | 0.75 s, 65 % | 65 % |
| tso-arm, first run | yes | 1.49 s, 68 % | 1.67 s, 64 % | 0.99 s, 49 % | 60 % |
| tso-arm, with profile | yes | 1.33 s, 76 % | 1.54 s, 69 % | 0.87 s, 56 % | 67 % |

Efficiency = native time / time; 100 % is native speed. Throttling flags after the run: 0xe0000.
<!-- efficiency:end -->

## Layout

| Path | Contents |
|---|---|
| `bench/` | microbenchmarks for the cost of ordered accesses on the host (AArch64), workload and efficiency runs |
| `litmus/` | x86-64 litmus tests that detect reordering, run natively and under translators |
| `tests/` | x86-64 programs that check the protocol's corner cases (shared stacks, many threads) |
| `fex/` | the FEX patch and its build scripts |
| `tools/` | sync and run scripts for the test machine |
| `docs/NOTES.md` | measurements, decisions and findings in order |

## Test machine

Raspberry Pi 5: Cortex-A76 (4 cores, 2.4 GHz), 16 GB, Debian 13, kernel 6.18 with 4 KB pages and 39-bit virtual
addresses. The A76 has LSE atomics and FEAT_LRCPC (`ldapr`), but not FEAT_LRCPC2 (`ldapur`), FEAT_LRCPC3 or FEAT_LSE2.

## License

MIT, see `LICENSE`: use, change and redistribute freely, keeping the copyright notice. The patch in `fex/patches/`
changes [FEX](https://github.com/FEX-Emu/FEX), which is MIT-licensed as well (copyright the FEX-Emu contributors);
the patched files keep FEX's notices.

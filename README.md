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
"x86 memory order kept" says whether the configuration is correct for multithreaded x86 programs. "Ahead of time"
rows run the program's hot functions translated ahead of time (`aot/`, a prototype; notes sections 16 and 17).
Updated with every change to the mechanism (`tools/readme_efficiency.py`).

<!-- efficiency:begin -->
Measured 2026-11-17T23:32, Raspberry Pi 5 at 1.8 GHz, 4 threads, best of the rounds, wall time.

| Configuration | x86 memory order kept | pigz | xz | zstd | geometric mean |
|---|---|---|---|---|---|
| native Arm | - | 1.00 s, 100 % | 1.08 s, 100 % | 0.50 s, 100 % | 100 % |
| FEX, TSO off | no | 1.14 s, 88 % | 1.37 s, 79 % | 0.60 s, 83 % | 83 % |
| tso-arm build, TSO off | no | 1.16 s, 86 % | 1.36 s, 79 % | 0.58 s, 86 % | 84 % |
| FEX default | no | 1.57 s, 64 % | 1.52 s, 71 % | 0.69 s, 72 % | 69 % |
| FEX full TSO | yes, except stack accesses through RSP | 1.64 s, 61 % | 1.55 s, 70 % | 0.75 s, 67 % | 66 % |
| tso-arm, first run | yes | 1.48 s, 68 % | 1.62 s, 67 % | 1.00 s, 50 % | 61 % |
| tso-arm, with profile | yes | 1.35 s, 74 % | 1.53 s, 71 % | 0.76 s, 66 % | 70 % |
| ahead of time, TSO off | no | 1.07 s, 93 % | 1.16 s, 93 % | 0.56 s, 89 % | 92 % |
| ahead of time, all ordered | yes, except stack accesses through RSP | 1.78 s, 56 % | 1.65 s, 65 % | 0.78 s, 64 % | 62 % |
| ahead of time + tso-arm, with profile | yes | 1.21 s, 83 % | 1.24 s, 87 % | 0.76 s, 66 % | 78 % |

Efficiency = native time / time; 100 % is native speed. Throttling flags after the run: 0xe0000.
<!-- efficiency:end -->

## Layout

| Path | Contents |
|---|---|
| `bench/` | microbenchmarks for the cost of ordered accesses on the host (AArch64), workload and efficiency runs |
| `litmus/` | x86-64 litmus tests that detect reordering, run natively and under translators |
| `tests/` | x86-64 programs that check the protocol's corner cases (shared stacks, many threads) |
| `fex/` | the FEX patches and their build scripts |
| `aot/` | translation of hot x86-64 functions to C ahead of time (`lift.py`), the library FEX loads with `TSO_AOT` |
| `tools/` | sync and run scripts for the test machine |
| `docs/NOTES.md` | measurements, decisions and findings in order |

## Test machine

Raspberry Pi 5: Cortex-A76 (4 cores, 2.4 GHz), 16 GB, Debian 13, kernel 6.18 with 4 KB pages and 39-bit virtual
addresses. The A76 has LSE atomics and FEAT_LRCPC (`ldapr`), but not FEAT_LRCPC2 (`ldapur`), FEAT_LRCPC3 or FEAT_LSE2.

## License

MIT, see `LICENSE`: use, change and redistribute freely, keeping the copyright notice. The patch in `fex/patches/`
changes [FEX](https://github.com/FEX-Emu/FEX), which is MIT-licensed as well (copyright the FEX-Emu contributors);
the patched files keep FEX's notices.

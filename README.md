# tso-arm

[![CI](https://github.com/DustinHab/tso-arm/actions/workflows/ci.yml/badge.svg)](https://github.com/DustinHab/tso-arm/actions/workflows/ci.yml)

Run x86-64 Linux programs on 64-bit Arm with x86's memory order kept, at up to 90 % of native speed.

Multithreaded x86 programs rely on x86's memory order: what one thread writes, the others see in the order it was
written. Arm processors do not guarantee that. An x86 emulator on Arm therefore orders every memory access, and that
is the largest single cost of x86 emulation; Apple avoids it with a switch in its own chips that other Arm processors
do not have. tso-arm orders only the memory that threads really share: each thread sees memory through views of
its own, and the processor's page protection reports the moment a second thread touches a page. On top of that, a
program's hot functions can be translated ahead of time. tso-arm is built on [FEX](https://github.com/FEX-Emu/FEX).

On a Raspberry Pi 5, x86 memory order kept, against native Arm builds of the same programs (geometric mean of pigz,
xz and zstd; the full table is below):

| | efficiency |
|---|---|
| **tso-arm**, with functions translated ahead of time | **82 %** (pigz 90 %, xz 90 %, zstd 69 %) |
| tso-arm, page protocol alone | 73 % |
| FEX, full TSO | 66 % |
| Box64, TSO mode (`BOX64_DYNAREC_STRONGMEM=4`) | 23 % |

## Quick start

On 64-bit Arm Linux with 4 KB pages (Debian, Ubuntu, Raspberry Pi OS with the 4 KB kernel):

```sh
sudo apt install git cmake ninja-build clang lld python3 python3-capstone binutils
sudo apt install linux-perf             # for 'learn' (Ubuntu: linux-tools-generic)
# Capstone 5 is needed for 'learn'; Ubuntu 24.04 packages 4: pip install --user capstone
git clone https://github.com/DustinHab/tso-arm && cd tso-arm
bin/tso-arm check                       # whether this machine can run it
bin/tso-arm install                     # FEX with the tso-arm patches, about 10 minutes on a Pi 5
bin/tso-arm run ./program args...       # an x86-64 Linux program, x86 memory order kept
bin/tso-arm learn ./program args...     # optional: translate its hot functions ahead of time
```

`learn` runs the program a few times with the given arguments (profile, then a check of the translated functions
against a run without them), so give it an input whose processing has no side effects. Afterwards every
`tso-arm run` of that program uses the translated functions; `tso-arm status` and `tso-arm forget` show and drop
what was learned. Dynamically linked programs need an x86-64 root file system (`tso-arm rootfs`, FEX's own tool);
ahead-of-time translation takes static, non-PIE programs for now.

## Why the order matters

`tests/spsc.c` is a ring buffer written the way x86 code often is: no barriers, it relies on x86's order. Under FEX
on the Pi 5, 20 million messages:

| | messages that arrived wrong |
|---|---|
| without ordering | 31 |
| FEX, full TSO | 0 |
| tso-arm | 0 |

Without ordering such programs mostly work and sometimes compute wrong results; with tso-arm they are correct, and
faster than with full ordering.

## How it works

- **Page protocol** (`fex/patches/`, notes sections 2 to 15): every thread reaches guest memory through a plain and
  an ordered view of its own (the same memory mapped twice per thread). A page one thread uses alone is mapped only
  in its views; when another thread touches it, a fault marks it shared, and from then on the accesses to it are
  ordered. Accesses to private memory stay plain and cost nothing extra. What a run learns (which instructions met
  shared memory) is kept in a profile for the next run.
- **Ahead of time** (`aot/`, notes sections 16 to 26): `aot/auto.py` picks a program's hot functions from a profile
  run, `aot/lift.py` translates them to C and clang to Arm code, with a plain and an ordered variant of each. A plain
  access that meets shared memory is patched at run time into an ordered one.
- **Fallback:** a program whose threads hand data back and forth constantly (zstd) or uses more threads at once than
  the address space has views for (15 on a 39-bit kernel) goes on with full ordering, as fast as FEX's own.

## Efficiency

x86-64 builds of zstd, pigz and xz under FEX, against native Arm builds of the same sources with the same compiler
options (`bench/build_native.sh`, `bench/efficiency.sh`). "x86 memory order kept" says whether the configuration is
correct for multithreaded x86 programs. "Ahead of time" rows run the program's hot functions translated ahead of
time, chosen from a profile by `aot/auto.py`. FEX's telemetry file, written with an `fsync` at every exit, is off in
every FEX configuration (notes section 22). Updated with every change to the mechanism (`tools/readme_efficiency.py`).

<!-- efficiency:begin -->
Measured 2026-11-18T18:40, Raspberry Pi 5 at 1.8 GHz, 4 threads, best of the rounds, wall time.

| Configuration | x86 memory order kept | pigz | xz | zstd | geometric mean |
|---|---|---|---|---|---|
| native Arm | - | 0.99 s, 100 % | 1.07 s, 100 % | 0.49 s, 100 % | 100 % |
| FEX, TSO off | no | 1.13 s, 88 % | 1.36 s, 79 % | 0.57 s, 86 % | 84 % |
| tso-arm build, TSO off | no | 1.13 s, 88 % | 1.33 s, 80 % | 0.57 s, 86 % | 85 % |
| FEX default | no | 1.56 s, 63 % | 1.51 s, 71 % | 0.67 s, 73 % | 69 % |
| FEX full TSO | yes, except stack accesses through RSP | 1.64 s, 60 % | 1.58 s, 68 % | 0.71 s, 69 % | 66 % |
| tso-arm, first run | yes | 1.37 s, 72 % | 1.55 s, 69 % | 0.93 s, 53 % | 64 % |
| tso-arm, with profile | yes | 1.25 s, 79 % | 1.48 s, 72 % | 0.73 s, 67 % | 73 % |
| ahead of time, TSO off | no | 1.06 s, 93 % | 1.15 s, 93 % | 0.55 s, 89 % | 92 % |
| ahead of time, all ordered | yes, except stack accesses through RSP | 1.75 s, 57 % | 1.64 s, 65 % | 0.71 s, 69 % | 63 % |
| ahead of time + tso-arm, with profile | yes | 1.10 s, 90 % | 1.19 s, 90 % | 0.71 s, 69 % | 82 % |

Efficiency = native time / time; 100 % is native speed. Throttling flags after the run: 0xe0000.
Every FEX configuration ran with FEX_DISABLETELEMETRY=1.
<!-- efficiency:end -->

Box64 on the same machine and programs (`bench/box64.sh`, notes section 25; it needs dynamically linked builds):
by default and with `BOX64_DYNAREC_STRONGMEM=1` it does not keep x86 order (forbidden litmus outcomes) and reaches
58 and 47 % (geometric mean); with x86 order kept (`STRONGMEM=4`) 23 %.

## Correctness

- **Litmus tests** (`litmus/`): message passing through plain and vector memory, `rep movs`, the stack, load
  buffering; forbidden x86 outcomes never show under tso-arm, also with translated thread functions, and do show
  without ordering.
- **CI** (`tests/ci.sh`, `.github/workflows/ci.yml`): every push builds tso-arm on one of GitHub's Arm servers and
  runs the litmus tests, the views' corner cases, more threads than views and the ring buffer there.
- **Other cores, emulated** (`tests/vm_run.sh`, notes section 27): Cortex-A53, Cortex-A72, Neoverse N1, Cortex-A710
  and Neoverse V1 in a full system emulation; all tests correct (one crash on the V1 with 20 threads that did not
  come back in 86 further runs there and 150 on the Pi).
- **Workload outputs** checked against native in every measurement.

## Where it runs

- **64-bit Arm Linux with 4 KB pages.** FEX needs them, and the views protect memory per 4 KB page; on a kernel with
  16 or 64 KB pages the views stay off and FEX orders everything itself.
- **FEAT_LRCPC** (`ldapr`, Cortex-A55/A75/A76 and later) makes ordered loads as cheap as plain ones. Older cores
  (Cortex-A53, A72) get `ldar` instead, which orders at least as strongly and costs more; both paths are tested.
- **Threads:** a thread with views of its own needs two 16 GB windows of address space, so 15 threads fit into a
  39-bit address space at once. With more, the program goes on with full ordering and the further threads share the
  views of others (correct, as fast as FEX's own full TSO).
- **Ahead of time** takes static, non-PIE x86-64 programs; what the translator cannot take stays with FEX.
- **Measured on the Raspberry Pi 5 only.** Other cores were tested for correctness in emulation; `tso-arm check` and
  `tools/board_check.sh --run` check, build and measure everything on a new board.

## Commands

| | |
|---|---|
| `tso-arm run [--mode tso\|full\|unordered] [--aot LIB] PROGRAM [ARGS]` | run an x86-64 program (default `tso`: x86 order kept) |
| `tso-arm learn PROGRAM [ARGS]` | translate its hot functions ahead of time and check them |
| `tso-arm status [PROGRAM]`, `tso-arm forget PROGRAM` | what was learned, and dropping it |
| `tso-arm check` | the machine's requirements |
| `tso-arm install [--generic]` | build FEX with the patches into `~/.local/opt/tso-arm` (`--generic`: for any Armv8.0 core) |
| `tso-arm rootfs` | an x86-64 root file system for dynamically linked programs |

## Layout

| Path | Contents |
|---|---|
| `bin/tso-arm` | the command |
| `fex/` | the FEX patches, `install.sh` and the build scripts of the test machine |
| `aot/` | translation of hot x86-64 functions to C ahead of time (`lift.py`, chosen by `auto.py`; the lists in `aot/lists/`) |
| `litmus/` | x86-64 litmus tests that detect reordering |
| `tests/` | correctness tests: CI, corner cases of the views, more threads than views, cores without `ldapr`, emulated cores |
| `bench/` | microbenchmarks of ordered accesses, workload and efficiency runs, Box64 |
| `tools/` | board check, sync and run scripts for the test machine |
| `docs/NOTES.md` | measurements, decisions and findings in order |

## Test machine

Raspberry Pi 5: Cortex-A76 (4 cores, 2.4 GHz), 16 GB, Debian 13, kernel 6.18 with 4 KB pages and 39-bit virtual
addresses. The A76 has LSE atomics and FEAT_LRCPC (`ldapr`), but not FEAT_LRCPC2 (`ldapur`), FEAT_LRCPC3 or FEAT_LSE2.

## License

MIT, see `LICENSE`: use, change and redistribute freely, keeping the copyright notice. The patch in `fex/patches/`
changes [FEX](https://github.com/FEX-Emu/FEX), which is MIT-licensed as well (copyright the FEX-Emu contributors);
the patched files keep FEX's notices.

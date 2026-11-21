# tso-arm

[![CI](https://github.com/DustinHab/tso-arm/actions/workflows/ci.yml/badge.svg)](https://github.com/DustinHab/tso-arm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DustinHab/tso-arm)](https://github.com/DustinHab/tso-arm/releases)

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
| **tso-arm**, with functions translated ahead of time | **83 %** (pigz 91 %, xz 88 %, zstd 70 %) |
| tso-arm, page protocol alone | 73 % |
| FEX, full TSO | 66 % |
| Box64, TSO mode (`BOX64_DYNAREC_STRONGMEM=4`) | 23 % |

Programs as Ubuntu ships them (xz with liblzma, gzip, bzip2 with libbz2, openssl's sha512), with their shared
libraries translated ahead of time: 83 % of the host's own Arm builds, against 61 % under FEX's full TSO.

## Quick start

On 64-bit Arm Linux with 4 KB pages (Ubuntu 22.04 and newer, Debian 12 and newer, Raspberry Pi OS with the 4 KB
kernel):

```sh
git clone https://github.com/DustinHab/tso-arm && cd tso-arm
bin/tso-arm install                     # FEX with the tso-arm patches, prebuilt: a few seconds
bin/tso-arm check                       # whether this machine can run it
bin/tso-arm rootfs                      # once, for dynamically linked programs: x86-64 Ubuntu from FEX's server
bin/tso-arm run ./program args...       # an x86-64 Linux program, x86 memory order kept
bin/tso-arm learn ./program args...     # optional: translate its hot functions ahead of time
```

`install` also links the command into `~/.local/bin`, so with that on the `PATH` it is just `tso-arm`. With
`sudo bin/tso-arm binfmt register`, x86-64 programs started directly (`./program`) run through tso-arm too, for the
whole system and after a reboot; `binfmt unregister` takes that back.

`run` needs `readelf` (binutils); `learn` needs `sudo apt install python3 python3-capstone clang linux-perf` as
well (Ubuntu: `linux-tools-generic` for perf; it needs Capstone 5, and Ubuntu packages 4: `pip install --user
capstone`). Without git, the [release package](https://github.com/DustinHab/tso-arm/releases) holds the same files
and the prebuilt FEX: unpack it and run `bin/tso-arm install` in it. The prebuilt FEX needs glibc 2.35 or newer; on
older systems, and with `install --source`, FEX is built from source (`git cmake ninja-build clang lld python3`,
about 10 minutes on a Pi 5). `tso-arm uninstall` removes it again; `CHANGELOG.md` lists what each release changed.

`learn` runs the program a few times with the given arguments (profile, then a check of the translated functions
against a run without them, then both timed against each other), so give it an input whose processing has no side
effects. Afterwards every `tso-arm run` of that program uses the translated functions, unless they made it slower
on this machine; `tso-arm status` and `tso-arm forget` show and drop what was learned.

Dynamically linked programs need an x86-64 root file system: `tso-arm rootfs` fetches Ubuntu 24.04 with FEX's own
tool (unpacked, about 2 GB, 95 s on a Pi 5), or `FEX_ROOTFS` names a directory with the x86-64 libraries. `learn`
translates such a program's own functions and those of its shared libraries: a shared library's translation is kept
under the library's name and build ID, and FEX takes it whenever a program maps that library (notes section 40). It
takes programs as distributions ship them, stripped and built with frame pointers and the stack protector: Ubuntu's
xz, whose work is all in liblzma, gzip and bzip2 reach 84 to 94 % of the host's own Arm builds, against 55 to 66 %
under FEX's full TSO (the table below). Where little of a program's time is in its own code, or its code calls
back and forth across the border to FEX all the time (an interpreter's loop, closures), `learn` finds the translation
slower and leaves it out (notes section 38).

pigz as distributions build it, on the Pi 5 (a 100 MB file, default clock; wall times as comments, output shortened,
`tools/readme_demo.sh`):

```console
$ file pigz
ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV), dynamically linked, ...
$ tso-arm run ./pigz -c data.tar > data.tar.gz            # 1122 ms
$ tso-arm learn ./pigz -c data.tar
tso-arm: pigz is dynamically linked: its own functions are translated, and those of its shared libraries (for every program that uses them)
profile: 28 guest functions, 98.1 % of the cycles in guest code
  hot      54.07 %  longest_match
  hot      23.80 %  deflate_slow
  hot       8.62 %  slide_hash
  ...
chosen: 21 functions, 97.8 of 98.1 % of the guest cycles
tso-arm: learned 21 functions of pigz; 'tso-arm run' uses them from now on
$ tso-arm run ./pigz -c data.tar > data.tar.gz            # 953 ms
$ tso-arm run --stats ./pigz -c data.tar > data.tar.gz
...
tso-arm: handled faults 308 in 0.010 s, block compiles 4403 in 0.039 s (all threads)
```

## Why the order matters

`tests/spsc.c` is a ring buffer written the way x86 code often is: no barriers, it relies on x86's order. 20 million
messages under FEX:

| | messages that arrived wrong, Raspberry Pi 5 (Cortex-A76) | GitHub's Arm runner (Neoverse N2) |
|---|---|---|
| without ordering | 31 | 507 |
| FEX, full TSO | 0 | - |
| tso-arm | 0 | 0 |

Without ordering such programs mostly work and sometimes compute wrong results; with tso-arm they are correct, and
faster than with full ordering.

## How it works

- **Page protocol** (`fex/patches/`, notes sections 2 to 15): every thread reaches guest memory through a plain and
  an ordered view of its own (the same memory mapped twice per thread). A page one thread uses alone is mapped only
  in its views; when another thread touches it, a fault marks it shared, and from then on the accesses to it are
  ordered. Accesses to private memory stay plain and cost nothing extra. What a run learns (which instructions met
  shared memory) is kept in a profile for the next run. Code and read-only data of a program and its libraries are
  mapped from their files, shared with every view and process (notes section 45).
- **One thread, no views** (notes section 46): a process with a single thread needs no ordering at all. Its code
  runs as without views, every access plain, until a second thread starts or it maps memory shared with another
  process; then what was translated goes and the page protocol takes over. Shells, build tools and most commands
  never get there.
- **Ahead of time** (`aot/`, notes sections 16 to 26, 29 and 40): `aot/auto.py` picks the hot functions of a
  program and of its shared libraries from a profile run, `aot/lift.py` translates them to C and clang to Arm code,
  with a plain and an ordered variant of each. FEX takes a shared library's translation when the program maps the
  library and gives it up when it unmaps it. A plain access that meets shared memory is patched at run time into an
  ordered one.
- **Fallback:** a program whose threads hand data back and forth constantly (zstd) or uses more threads at once than
  the address space has views for (15 on a 39-bit kernel) goes on with full ordering, as fast as FEX's own.
- **Compile units** (notes section 43): FEX compiles from each place a function is entered everything reachable
  from there; tso-arm limits that to 150 instructions (`FEX_MAXINST`), so programs with large functions entered at
  many points (ffmpeg, Node) no longer compile the same code again and again.

## Efficiency

x86-64 builds of zstd, pigz and xz under FEX, against native Arm builds of the same sources with the same compiler
options (`bench/build_native.sh`, `bench/efficiency.sh`). "x86 memory order kept" says whether the configuration is
correct for multithreaded x86 programs. "Ahead of time" rows run the program's hot functions translated ahead of
time, chosen from a profile by `aot/auto.py`. FEX's telemetry file, written with an `fsync` at every exit, is off in
every FEX configuration (notes section 22). Updated with every change to the mechanism (`tools/readme_efficiency.py`).

<!-- efficiency:begin -->
Measured 2026-11-20T22:14, Raspberry Pi 5 at 1.8 GHz, 4 threads, best of the rounds, wall time.

| Configuration | x86 memory order kept | pigz | xz | zstd | geometric mean |
|---|---|---|---|---|---|
| native Arm | - | 1.00 s, 100 % | 1.07 s, 100 % | 0.49 s, 100 % | 100 % |
| FEX, TSO off | no | 1.13 s, 88 % | 1.34 s, 80 % | 0.57 s, 86 % | 85 % |
| tso-arm build, TSO off | no | 1.13 s, 88 % | 1.34 s, 80 % | 0.57 s, 86 % | 85 % |
| FEX default | no | 1.56 s, 64 % | 1.51 s, 71 % | 0.68 s, 72 % | 69 % |
| FEX full TSO | yes, except stack accesses through RSP | 1.64 s, 61 % | 1.54 s, 69 % | 0.71 s, 69 % | 66 % |
| tso-arm, first run | yes | 1.32 s, 76 % | 1.53 s, 70 % | 0.85 s, 58 % | 67 % |
| tso-arm, with profile | yes | 1.26 s, 79 % | 1.51 s, 71 % | 0.71 s, 69 % | 73 % |
| ahead of time, TSO off | no | 1.06 s, 94 % | 1.17 s, 91 % | 0.56 s, 87 % | 91 % |
| ahead of time, all ordered | yes, except stack accesses through RSP | 1.76 s, 57 % | 1.55 s, 69 % | 0.70 s, 70 % | 65 % |
| ahead of time + tso-arm, with profile | yes | 1.10 s, 91 % | 1.21 s, 88 % | 0.70 s, 70 % | 83 % |

Efficiency = native time / time; 100 % is native speed. Throttling flags after the run: 0xe0000.
Every FEX configuration ran with FEX_DISABLETELEMETRY=1.
<!-- efficiency:end -->

**Programs as distributions ship them** (`bench/distro.sh`, notes section 40): the x86-64 builds of Ubuntu 24.04
from `tso-arm rootfs`, dynamically linked, their work mostly in shared libraries, against the host's own Arm builds
of the same programs (Raspberry Pi OS: other versions, so the native column is a guide, not the same code). Each
program learned once with `tso-arm learn`.

<!-- distro:begin -->
Measured 2026-11-20T22:27, Raspberry Pi 5 at 1.8 GHz, best of the rounds, wall time; the Ubuntu 24.04 x86-64 builds against the host's Arm builds.

| Program (its library) | native Arm | FEX full TSO | tso-arm, page protocol | tso-arm, learned |
|---|---|---|---|---|
| xz (liblzma) | 1.06 s, 100 % | 1.67 s, 63 % | 1.55 s, 68 % | 1.25 s, 85 % |
| gzip (-) | 3.59 s, 100 % | 5.40 s, 66 % | 4.28 s, 84 % | 3.80 s, 94 % |
| bzip2 (libbz2) | 1.02 s, 100 % | 1.87 s, 55 % | 1.36 s, 75 % | 1.21 s, 84 % |
| openssl (libcrypto, sha512) | 0.39 s, 100 % | 0.65 s, 60 % | 0.57 s, 68 % | 0.56 s, 70 % |
| geometric mean | 100 % | 61 % | 74 % | 83 % |

Efficiency = native time / time. Throttling flags after the run: 0xe0000. Every output checked.
<!-- distro:end -->

Where tso-arm gains least: openssl's sha512 is hand-written assembly in libcrypto that `learn` cannot translate (it
reads the stack pointer as a value), with few memory accesses to order; it runs as FEX translates it, with one
thread, so without views and without ordering (notes sections 40, 42 and 46).

Box64 on the same machine and programs (`bench/box64.sh`, notes section 25; it needs dynamically linked builds):
by default and with `BOX64_DYNAREC_STRONGMEM=1` it does not keep x86 order (forbidden litmus outcomes) and reaches
58 and 47 % (geometric mean); with x86 order kept (`STRONGMEM=4`) 23 %.

## Correctness

- **Litmus tests** (`litmus/`): message passing through plain and vector memory, `rep movs`, the stack, load
  buffering; forbidden x86 outcomes never show under tso-arm, also with translated thread functions, and do show
  without ordering.
- **CI** (`tests/ci.sh`, `.github/workflows/ci.yml`): every push builds tso-arm on one of GitHub's Arm servers (a
  Neoverse N2, at times a V3: 48-bit addresses, FEAT_LRCPC2 and LSE2) and runs the litmus tests, the views' corner
  cases, more threads than views, fork without exec, private file mappings, the program's signal handlers, signals
  that meet (two at once, one raised while another thread changes its action), x87 arithmetic, a dynamically linked
  program, a shared library translated ahead of time that the program loads and
  unloads three times, and the ring buffer there, also after a start with one thread (the views asleep); then it
  measures the efficiency of pigz, xz and zstd on that machine
  (`tests/ci_bench.sh`, in the run's summary). Every week the same tests run with the patches on FEX's newest commit
  (`.github/workflows/upstream.yml`); on demand, `.github/workflows/profile.yml` profiles a workload there
  (`tests/ci_profile.sh`: per guest function, translated against FEX's own code).
- **Programs of a distribution** (`tests/compat.sh`, `.github/workflows/compat.yml`, notes sections 35 and 47):
  sort, 7-Zip, Python with threads, ffmpeg with x264, Node with worker threads and Java from x86-64 Ubuntu, packed
  with their libraries (`tools/compat_rootfs.sh`); on the Pi 5 (best of 3, default clock, the profiles from
  nothing):

  | | tso-arm | FEX, full TSO | FEX, no ordering | output |
  |---|---|---|---|---|
  | sort, 4 threads | 2281 ms | 2865 ms | 2597 ms | the same |
  | 7-Zip, xz with 4 threads | 3467 ms | 3513 ms | 3495 ms | the same |
  | Python, threads | 2962 ms | 2955 ms | 2173 ms | the same |
  | ffmpeg, x264 with 4 threads | 1753 ms | 2951 ms | 2270 ms | the same |
  | Node, worker threads | 4988 ms | 7859 ms | 6918 ms | the same |
  | Node, messages seen before their data | 0 | 0 | 105,922 | |
  | Java, parallel sort and streams | 4042 ms | 4272 ms | 2854 ms | the same |
  | Java, messages seen before their data | 0 | 0 | 3,131,256 | |

  sort, ffmpeg and Node faster than FEX without any ordering: tso-arm has FEX compile smaller units (notes section
  43).

  The message rows: JavaScript through a SharedArrayBuffer with plain stores, Java with a release store and an
  acquire load (a correct Java program). V8 and HotSpot compile them to plain x86 moves at run time, and only x86
  order keeps the reader from seeing the flag before the data. HotSpot crashes in 1 to 3 of 30 runs under FEX,
  with the patches and without (in code it has just compiled); `tests/compat.sh` repeats such a run and says so.
- **Everyday programs** (`tests/rootfs_check.sh`, notes sections 39 and 44): 28 commands of the root file system
  `tso-arm rootfs` fetches (shell pipelines, command substitution, traps and job control, coreutils, gzip, xz, tar,
  perl, Python with subprocess, a fork pool, fork beside running threads and signal handlers, git packing a
  repository with 4 threads, make with 4 jobs, rsync) give the same output as under FEX's full ordering.
- **CPython's own tests** (`tests/cpython_suite.sh`, notes section 47): the tests of threads, locks, queues,
  signals, fork, memory maps, selectors and `concurrent.futures` from the interpreter's own release (Python 3.12.3,
  750 cases), run by the root file system's python3: no case fails under tso-arm that passes under FEX's full
  ordering, and none fails under either. They found three faults in signal delivery, two of them FEX's own
  (`test_signal` crashed under FEX without the patches in every run), fixed in the patches. A wider run, 47 test
  files with 5,297 cases (also subprocess, os, io, sockets, select, poll and epoll, asyncio, multiprocessing with a
  fork server, pty, fcntl, faulthandler): the same 5 fail in both modes, FEX's (the file descriptors FEX keeps open
  in every process, which a child that lists its own sees).
- **Rare failures** (`tests/soak.sh`, notes sections 44 and 46): git, xz, sort, Python and make with 4 threads or
  jobs, 100 runs each with the profile, without one and block by block, every output against full ordering: 1,500
  of 1,500 right (every run wakes the views once); in CI 5 runs each.
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
- **fork:** the views need guest memory to be shared memory, which the kernel's copy-on-write does not cover, so a
  forked child copies the program's writable memory while its parent waits (notes section 39): about 1 ms more per
  fork on the Pi, plus the copy of a large heap. Read-only memory stays shared until it is made writable; vfork and
  `posix_spawn` cost nothing extra.
- **Ahead of time** takes a program's own functions, static or position-independent (PIE), linked statically or
  dynamically, and those of its shared libraries that have a build ID (distributions build them with one); what the
  translator cannot take stays with FEX.
- **Measured in detail on the Raspberry Pi 5**, and in every CI run on GitHub's Arm runner (notes sections 32 and
  33; the latest on a Neoverse N2: with x86 order kept pigz 78 % and xz 94 %, against 68 and 73 % under FEX's full
  TSO; zstd as fast as FEX's full TSO, since `learn` found its translated functions slower there and left them out;
  single runs there spread by several points). Other cores were tested for correctness in emulation; `tso-arm check` and `tools/board_check.sh --run` check, build and measure
  everything on a new board.

## Commands

| | |
|---|---|
| `tso-arm run [--mode tso\|full\|unordered] [--aot LIB] PROGRAM [ARGS]` | run an x86-64 program (default `tso`: x86 order kept) |
| `tso-arm learn PROGRAM [ARGS]` | translate its hot functions ahead of time, check them, keep them if faster |
| `tso-arm status [PROGRAM]`, `tso-arm forget PROGRAM` | what was learned, and dropping it |
| `tso-arm check` | the machine's requirements |
| `tso-arm install [--source\|--generic]` | FEX with the patches into `~/.local/opt/tso-arm`, prebuilt; `--source`: built for this core, `--generic`: built for any Armv8.0 core |
| `tso-arm uninstall [--all]` | remove FEX and the command (`--all`: what was learned as well) |
| `tso-arm rootfs [OPTIONS]` | an x86-64 root file system for dynamically linked programs (Ubuntu 24.04 without options) |
| `tso-arm binfmt [register \| unregister]` | x86-64 programs started directly (`./program`) run through tso-arm; register and unregister need root |
| `tso-arm version` | the version, and the FEX it uses |

## Layout

| Path | Contents |
|---|---|
| `bin/tso-arm` | the command |
| `fex/` | the FEX patches, `install.sh` and the build scripts of the test machine |
| `tools/package.sh`, `tools/release_notes.sh`, `.github/workflows/release.yml` | the release packages (FEX prebuilt for any Armv8.0 core) and their notes from `CHANGELOG.md` |
| `aot/` | translation of hot x86-64 functions to C ahead of time (`lift.py`, chosen by `auto.py`; the lists in `aot/lists/`) |
| `litmus/` | x86-64 litmus tests that detect reordering |
| `tests/` | correctness tests: CI, corner cases of the views, more threads than views, cores without `ldapr`, emulated cores, programs of a distribution |
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

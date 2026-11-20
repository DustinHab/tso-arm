# Changes

## 0.2.0 (2026-11-20)

Programs as distributions ship them. `tso-arm learn` translates stripped programs built with frame pointers, the
stack protector and gcc's split-off cold parts, keeps what it translated only where that makes the program faster
on the machine at hand, and translated code returns 16-byte results right. Programs of x86-64 Ubuntu (sort, 7-Zip,
Python, ffmpeg with x264, Node) are tested on every push: the same output in every mode, as fast as under FEX's full
TSO or faster, and message passing between Node's threads that keeps x86's order. On the Raspberry Pi 5, with x86
order kept: 82 % of native speed (pigz 90 %, xz 88 %, zstd 70 %).

Install: download `tso-arm-0.2.0-linux-arm64.tar.gz`, unpack it and run `tso-arm-0.2.0/bin/tso-arm install`, or
`bin/tso-arm install` in a clone. The FEX patches changed: `tso-arm` refuses an FEX installed for 0.1.0 until
`tso-arm install` replaces it, and FEX does not use what `learn` translated with 0.1.0 (it says so; `learn`
translates it again).

- **Programs of a distribution** (`tests/compat.sh`, `tools/compat_rootfs.sh`): sort, 7-Zip, Python with threads,
  ffmpeg with x264 and Node with worker threads from x86-64 Ubuntu, run with x86 order kept, with FEX's full TSO and
  without ordering, outputs compared, on every push (`.github/workflows/compat.yml`).
- **`learn` on such programs**: functions of stripped programs from the unwind information; frame pointers; cold
  parts; thread-local storage (the stack protector's canary); calls of guest functions whose stack arguments cannot
  be told. pigz, xz and zstd built the distributions' way translate fully.
- **`learn` measures before it keeps**: the program as `tso-arm run` runs it, with the library, with it and FEX's
  multiblock, and without; a slower library is not used (`tso-arm status` says so). It stops with the program's exit
  status when the program fails with the given arguments.
- **Fixed**: translated functions return rdx as well as rax (Rust's slices, C++'s pairs), as a pair in two
  registers; libraries carry the number of their interface. A tail call from translated code into guest code could
  overwrite the guest caller's return address when the function had been entered from guest code that translated
  code had called. The escape analysis follows addresses through vector registers.
- **Newer cores**: ordered accesses with an offset in the instruction (`ldapur`, `stlur`, FEAT_LRCPC2), and unaligned
  `ldapr`/`stlr` within 16 bytes where the kernel allows them (FEAT_LSE2), each measured against a build without it
  in the CI. The test for stack objects in host memory takes one instruction instead of four.
- **CI**: the benchmark fails on a wrong output (it went on before); `.github/workflows/profile.yml` profiles a
  workload on GitHub's Arm runner on demand, per guest function, translated against FEX's own code.

## 0.1.0 (2026-11-20)

The first release: x86-64 Linux programs on 64-bit Arm with x86's memory order kept, at 83 % of native speed on a
Raspberry Pi 5 (geometric mean of pigz 90 %, xz 90 %, zstd 70 %), against 66 % for FEX's own full TSO and 23 % for
Box64 with x86 order kept.

Install: download `tso-arm-0.1.0-linux-arm64.tar.gz`, unpack it and run `tso-arm-0.1.0/bin/tso-arm install`; it
installs the prebuilt FEX in seconds. From a clone of the repository, `bin/tso-arm install` fetches the same FEX.
The prebuilt FEX runs on 64-bit Arm Linux with glibc 2.35 or newer (Ubuntu 22.04 and newer, Debian 12 and newer,
Raspberry Pi OS) and 4 KB pages; `tso-arm check` tells whether a machine fits.

- **The command** `tso-arm`: `run` (modes `tso`, `full`, `unordered`; `--stats`), `learn`, `status`, `forget`,
  `check`, `install` (prebuilt, or from source with `--source` and `--generic`), `uninstall`, `rootfs`, `version`.
- **Page protocol** in FEX: every thread reaches guest memory through a plain and an ordered view of its own; only
  memory that a second thread touches is ordered. What a run learns is kept for the next run. A program that shares
  data constantly, or runs more threads at once than there are views, goes on with full ordering.
- **Ahead of time:** `tso-arm learn` profiles a program, translates its hot functions to Arm code through C and
  checks them against a run without; later runs use them. Static and position-independent programs, and the own
  functions of dynamically linked ones (their libraries stay with FEX). Built the way distributions build them,
  pigz reaches 82 % and xz 85 %. On cores with FEAT_LRCPC2 the ordered accesses carry their offset in the
  instruction (`ldapur`, `stlur`).
- **Correctness:** litmus tests for message passing through plain and vector memory, `rep movs`, the stack and load
  buffering show no forbidden x86 outcome, also with translated functions. Every push runs them on GitHub's
  Neoverse N2; every week they run with the patches on FEX's newest commit. Cortex-A53, A72, A710, Neoverse N1 and
  V1 were tested in a full system emulation.
- **Measured on GitHub's Neoverse N2:** with x86 order kept pigz 85 % and xz 90 %, against 71 and 70 % under FEX's
  full TSO.

Known limits:

- zstd's threads hand data back and forth constantly, so it runs with full ordering (70 % on the Pi 5, about as fast
  as FEX's full TSO; on the N2 slightly below it).
- Kernels with 16 or 64 KB pages: the views stay off and FEX orders everything itself.
- Functions of shared libraries are not translated ahead of time (in the programs measured, under 2 % of the time).
- Built on FEX be66e03 (2026-11-16); the patches are in `fex/patches/`.

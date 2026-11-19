# Changes

## 0.1.0 (2026-11-19)

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
  pigz reaches 82 % and xz 85 %.
- **Correctness:** litmus tests for message passing through plain and vector memory, `rep movs`, the stack and load
  buffering show no forbidden x86 outcome, also with translated functions. Every push runs them on GitHub's
  Neoverse N2; every week they run with the patches on FEX's newest commit. Cortex-A53, A72, A710, Neoverse N1 and
  V1 were tested in a full system emulation.
- **Measured on GitHub's Neoverse N2:** with x86 order kept pigz 84 % and xz 93 %, against 72 and 71 % under FEX's
  full TSO.

Known limits:

- zstd's threads hand data back and forth constantly, so it runs with full ordering (70 % on the Pi 5, about as fast
  as FEX's full TSO; on the N2 slightly below it).
- Kernels with 16 or 64 KB pages: the views stay off and FEX orders everything itself.
- Functions of shared libraries are not translated ahead of time (in the programs measured, under 2 % of the time).
- Built on FEX be66e03 (2026-11-16); the patches are in `fex/patches/`.

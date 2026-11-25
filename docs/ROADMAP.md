# What is missing for everyday use

tso-arm runs command-line x86-64 programs correctly and fast. What people run on an Arm computer is wider than that:
32-bit programs, programs with a window and a GPU, Windows programs through Wine, containers, and they install it
without a compiler or a terminal session of explanations. The list below is what stands between tso-arm and that,
ordered by how many people it stops. It is worked through from the top; each item says what was found and what was
done.

| | Item | State |
|---|---|---|
| 1 | 32-bit x86 programs | done (0.4.4) |
| 2 | Starting without binutils | done (0.4.4) |
| 3 | Raspberry Pi OS on a Pi 5 boots a 16 KB-page kernel | done (0.4.4) |
| 4 | GPU acceleration for x86 programs (FEX's thunks) | when asked for (0.4.4); FEX's thunks are incomplete |
| 5 | Installing for every user, in one line, and updating | done (0.4.4) |
| 6 | Containers: `docker run --platform linux/amd64` | open |
| 7 | Windows programs through Wine, AppImages, programs with a window: tested | done (0.4.4): `tso-arm wine` (full ordering for now), three faults fixed |
| 8 | The page protocol for 32-bit programs | open |
| 9 | A guide for users: what runs, what to do when something does not | done (0.4.4): `docs/GUIDE.md`, `tso-arm report` |
| 10 | Rebase onto FEX's newest commit (the stage 3 patch conflicts in `SignalDelegator.cpp` there) | open |
| 11 | The page protocol for Wine: explorer.exe children left waiting on a lock of the guest's C library | open |

## 1. 32-bit x86 programs

FEX runs them, and the patched FEX does: a static and a dynamically linked i386 program (glibc from the root file
system, which carries 480 i386 libraries for Steam and Wine), message passing, load buffering, vector and string
stores without a forbidden outcome (`litmus/mp32.c`). The page protocol does not engage in 32-bit mode, so FEX orders
every access itself, as fast as `--mode full`. But `tso-arm run` refused them ("not an x86-64 Linux program") and
`binfmt register` registered only x86-64.

Done: `tso-arm run` takes them (in the default mode as with `--mode full`), `binfmt register` registers both
machines, `learn` says it translates x86-64 code only. `tests/ci.sh` runs the 32-bit litmus tests and a 32-bit
threads test, and CI starts a 32-bit program directly through binfmt_misc.

## 2. Starting without binutils

`tso-arm run` read a program's ELF header and build ID with `readelf`, which a desktop installation of Ubuntu or
Raspberry Pi OS does not have.

Done: it reads them itself with `od` and `awk` from the first kilobyte of the file (the first 64 KB where headers
lie further in). On the Pi 5 `tso-arm run` starts 3 to 5 ms sooner than with three `readelf` calls;
`tests/elfinfo_check.sh` finds the same as `readelf` for 1,084 programs and libraries of the x86-64 root file
system, x86-64 and i386.

## 3. Raspberry Pi OS on a Pi 5

Raspberry Pi OS boots the Pi 5 with a 16 KB-page kernel (`kernel_2712.img`). FEX needs 4 KB pages; the 4 KB kernel is
on the card as well (`kernel8.img`) and one line in `/boot/firmware/config.txt` selects it. `tso-arm check` said only
that the page size is wrong.

Done: `tools/pages_hint.sh`, run by `tso-arm check` and `tso-arm install`, names that line on a Raspberry Pi, says
on Apple silicon that x86 programs run in a 4 KB-page virtual machine there (Asahi's muvm), and elsewhere which kernel
option is needed.

## 4. GPU acceleration

x86 programs draw with the x86 Mesa of the root file system. Ubuntu's x86 Mesa has no driver for the Pi's V3D (nor
for Panfrost on Rockchip boards): OpenGL falls back to the CPU (llvmpipe), Vulkan to lavapipe. FEX's thunks forward
OpenGL, EGL, Vulkan and other libraries to the host's own Arm libraries; tso-arm's FEX was built without them.

Done so far: the release workflow builds the prebuilt FEX with its thunks (libclang 14 on Ubuntu 22.04, the x86 cross
C++ libraries), and `tso-arm run --gpu` points FEX at them and selects the Vulkan thunk, with OpenGL through the
x86 Mesa's Zink onto it (FEX's OpenGL thunk stopped with an X error on Xvfb). A FEX patch lets a prebuilt FEX
find its data directory beside itself (the thunks' database and guest libraries were looked for under the prefix of
the build machine). `tests/gpu_info.c` on the Pi 5:

| | Vulkan device | start |
|---|---|---|
| x86-64, without thunks | llvmpipe (x86 Mesa, the CPU) | 541 ms |
| x86-64, `--gpu` | V3D 7.1.10.2 (the host's driver) | 185 ms |
| 32-bit, `--gpu` | llvmpipe: FEX has no 32-bit Vulkan thunk | 587 ms |

Why not by default: Ubuntu's `vulkaninfo` stops with SIGILL through FEX's Vulkan thunk in every ordering mode when
its output goes to a file (to a terminal it finishes), FEX's EGL thunk lacks `eglGetConfigs` and `eglQueryString`
(FEX's database has no entry for it), and OpenGL through GLX could not be tried on the Pi without an X server. FEX
leaves its thunks off by default for the same reason. Open: a program with a window under Xvfb in CI with and without
`--gpu`, and where `vulkaninfo` stops.

## 5. Installing for every user, and updating

`tso-arm install` installs into the home directory of whoever runs it; `binfmt register` then points the whole system
at a program in that home directory. Installing needs git or a downloaded package, and there is no way to update to a
newer release but doing it again.

Done: `tools/get.sh`, run with one line from the README, installs the newest release with its prebuilt FEX, for the
user (`~/.local/share/tso-arm`) or as root for everyone (`/opt/tso-arm`, binfmt_misc registered by the link to the
version in use). Versions lie side by side; `tso-arm update` installs the newest (never an older one unless asked),
the one before stays until the next update; `tso-arm uninstall` removes it all. `tso-arm run` takes the FEX a
release package brings along without installing it. As root, `tso-arm rootfs` fetches one root file system for every
user of such an installation. Checked on the Pi as a user in a throwaway home directory and in CI as root (install,
programs started directly, update, removal).

## 6. Containers

On Arm servers and laptops, x86-64 container images run through binfmt_misc with an emulator registered with the
`F` flag, so that it is found inside the container's own file system. That needs an interpreter without a dynamic
loader of its own: FEX is dynamically linked against the host's libraries.

Looked at: FEX's build has no static variant, and FEX will not start without its server (FEXServer, which it starts
from its own path when none answers on its socket); inside a container both the server's socket (an abstract one,
per network namespace) and the libraries the server and FEX link are missing. A container needs FEX and FEXServer
linked statically (or the host's Arm libraries mounted in), and FEX's root file system set to the container's own
`/`. Not started.

## 7. Wider tests

CI runs command-line programs from x86-64 Ubuntu (sort, 7-Zip, Python, ffmpeg, Node, Java, Go, git, make). Not yet:
Wine with a Windows program, an AppImage, a program with an X11 window.

AppImages: an AppImage mounts its contents with FUSE through a `fusermount` it looks for on the PATH, which inside
the root file system has none, and stopped ("Cannot mount AppImage"). Unpacked instead (`APPIMAGE_EXTRACT_AND_RUN`,
which `tso-arm run` now sets for them) the official `appimagetool` AppImage runs on the Pi 5 and builds an AppImage
itself; a 15 MB one starts in 0.36 s, 0.33 s from a copy unpacked beforehand, so nothing is kept.

Wine: `tso-arm wine` fetches WineHQ's Wine 11 for Ubuntu 24.04 and runs Windows programs through it, with the root
file system of `tso-arm rootfs`. Under full ordering it ran a ring buffer between two Win32 threads right at once;
with the page protocol Wine did not start, for two faults of the views (notes section 58): mappings with `PROT_WRITE`
alone (wineserver), and segment register loads (Wine's ntdll in its signal handler). Both fixed, with tests of their
own. The Wine workflow runs WineHQ's Wine through `tso-arm wine` with the root file system of `tso-arm rootfs`, as a
user does (Ubuntu's wine64 packed into a root file system of its own did not find kernel32.dll; dropped).

Programs with a window: `tests/graphics_check.sh` in the Compat workflow runs glxinfo, glxgears and vkcube from
the root file system on Xvfb, with the x86 Mesa and with `--gpu`.

## 8. The page protocol for 32-bit programs

32-bit programs run with FEX's full ordering (item 1). The views would need 4 GB windows per thread instead of 16 GB
and the translated code's 32-bit addresses based on them.

## 9. A guide for users

The README describes the mechanism and its measurements. A user needs: what runs (and how fast), the commands for
the common cases, and what to do when a program does not run (`tso-arm check`, `--mode full`, what to report).

Done so far: `tso-arm report [PROGRAM ARGS]` puts versions, machine, root file system, settings and, for a program,
how it ends in each ordering mode into one block; the issue template asks for it.

## 10. FEX's newest commit

The patches are made on FEX be66e03 (2026-11-16) and applied to it in every build. FEX's main branch has moved on
since: stage 2 still applies with a three-way merge, stage 3 conflicts in `SignalDelegator.cpp`. The weekly
`upstream.yml` run against FEX's main fails until the patches are rebased.

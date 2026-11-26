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
| 6 | Containers: `docker run --platform linux/amd64` | done (0.4.5), 64-bit and 32-bit programs |
| 7 | Windows programs through Wine, AppImages, programs with a window: tested | done (0.4.4): `tso-arm wine`, three faults fixed |
| 8 | The page protocol for 32-bit programs | open |
| 9 | A guide for users: what runs, what to do when something does not | done (0.4.4): `docs/GUIDE.md`, `tso-arm report` |
| 10 | Rebase onto FEX's newest commit (the stage 3 patch conflicts in `SignalDelegator.cpp` there) | done (0.4.5): FEX 8e980598 |
| 11 | The page protocol for Wine: explorer.exe children left waiting on a `pthread_once` of Wine's win32u | done (0.4.5): `tso-arm wine` under the page protocol |
| 12 | fork after the views fell back to full ordering | done (0.4.5) |
| 13 | i386 programs of glibc 2.35 and older crash at their first system call under FEX | done (0.4.6), FEX's own fault |
| 14 | Start-up: every run translates a program's code anew | done (0.4.6): FEX's disk cache, bound to the page protocol's state |

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

Why not by default: FEX's EGL thunk lacks `eglGetConfigs` and `eglQueryString` (FEX's database has no entry for it),
and OpenGL through GLX could not be tried on the Pi without an X server. FEX leaves its thunks off by default for the
same reason. A program with a window runs under Xvfb in CI with and without `--gpu` (item 7).

Where `vulkaninfo` stopped (found and fixed for 0.4.6): it chains a debug messenger into `vkCreateInstance`, whose
function is the program's own x86 code. FEX's Vulkan thunk passed the chain to the host's loader as it was, and the
loader called that function for its first warning as Arm code: SIGILL, reported at the last guest address FEX had
entered (the trampoline of `vkEnumeratePhysicalDevices`, which looked like a link that had not taken). The thunk took
only the older debug report structure out of such chains. Now every structure that hands the host a guest function
(debug messengers and reports, a device memory report, a list of drivers to load) is taken out for the call and put
back after it; `tests/vkproc.c` chains a messenger for every severity, and the graphics check runs it and `vulkaninfo
--summary` with and without `--gpu`. A fault of FEX's own.

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
per network namespace) and the libraries the server and FEX link are missing.

Done: FEX's program linked statically as well, as a position-independent executable (`FEX-static`, built beside
FEX; static-pie, since a static executable at x86's usual address would sit where x86 programs load), in the
release package and in every build from source where the static C and C++ libraries are there. `tso-arm binfmt
register` registers it with the `F` and `P` flags (the program's own `argv[0]` kept). Started by the kernel, it looks
for the host's installation: where the script beside it is in reach, and a shell of the host's own architecture to
run it, it hands the program on to `tso-arm run`, as before; elsewhere, in a container, it runs the program itself,
without the server, on the container's own files (no root file system), with tso-arm's settings (`TSO_ARM_MODE`).
`tests/container_check.sh` in CI: `uname -m` in Ubuntu 24.04's image, the threads test linked statically and against
the container's own C library, fork with threads, signals, and `apt-get install python3` with Python's threads
afterwards, a 32-bit program; and a container started after the installation for every user.

The statically linked FEX crashed at once with a 32-bit program, and with any on GitHub's runner (48-bit addresses):
rpmalloc's heap pointer for the main thread had become 0. FEX's allocator for its own memory (above a 32-bit
program's 4 GB, above 47 bits on a 48-bit host) cleared each region it took into use with `madvise(MADV_DONTNEED)`
from a page into the region for the region's whole length, one page past its end: the first page of the next
mapping was thrown away. A statically linked C library keeps the main thread's thread-local storage in the brk heap,
which lay right there; FEX as built before lost a page of a library or the stack there, mostly without harm. Fixed
in the patch (up to the region's end); found with a watchpoint that never fired (the kernel cleared the page) and a
catchpoint on the system calls that touch that address.

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

The patches were made on FEX be66e03 (2026-11-16). FEX's main branch had moved on by 44 commits: stage 2 applied
with a three-way merge, stage 3 conflicted in `SignalDelegator.cpp`, where FEX moved its synchronous faults (`ud2`,
`int3`, a fault the translated code raises itself) from the dispatcher's own blocks into the frontend
(`SynchronousExceptionHandler`), next to tso-arm's helper for the host signal stack.

Done: the patches on FEX 8e980598 (2026-11-24), the conflict merged (both kept; FEX's helper for signal masks went,
which the patches no longer used), and the commit the patches apply to named in one place (`fex/install.sh`), which
`build_views.sh` and `export_views.sh` read. CI, the compatibility and the Wine workflows pass on it.

## 11. The page protocol for Wine

`tso-arm wine` runs Wine with full ordering (item 7): under the page protocol orphaned `explorer.exe` processes are
left waiting, more of them with every program that needs the desktop (it starts another explorer each time).

Found so far (notes section 59): the word they wait on is a `pthread_once` in Wine's `win32u.so` (its `.bss`), the one
around `register_builtin_classes`, which registers the built-in window classes and then calls back into user32 on
the Windows side (`KeUserModeCallback`). The explorer process has one thread throughout; it forks twice (Wine
starting processes) and then waits on that `pthread_once` with the value 1, "in progress": its own initialization
called `NtUserCreateWindowEx` again from within the callback and waits for itself. Under full ordering it does not.
On the way, a fault of the views' own was found and fixed: a fork after the fallback to full ordering gave the child
memory written after the fork (item 12); the explorer processes are left waiting with that fixed as well.

The cause (Wine's own traces, `warn+winstation`): `Session object id doesn't match expected id`, and so `Failed to get
shared session object for window class` and `failed to create desktop window`, after which the explorer starts
another explorer and ends in the recursion above. wineserver writes the session's objects into a file it grows; every
Wine process maps that file, on Linux on purpose as a private mapping with read and write rights (Wine relies on Linux
showing the file's later changes in a private mapping not written to). The views copy a writable private file
mapping when it is made: the process kept what the file held then, and every object wineserver added later read
wrong. Two smaller faults of the same kind were found and fixed on the way (0.4.5): a read-only private mapping past
the file's end was zeros of its own (`tests/filegrow.c`), and a `MAP_FIXED` mapping over memory another thread's views
mapped left those views on the old memory.

Done (0.4.5): a writable private mapping of a file without a name (deleted, or a memfd: memory another process shares
through it, as wineserver's sections) is the file itself, without the host's write right, until its first write: the
fault copies the whole range then (the kernel copies page by page; once written, the range no longer shows the
file's later changes) and the write runs again. On GitHub's runner no explorer.exe is left under the page protocol
now, as under full ordering, and `tso-arm wine` runs Wine under it (`TSO_ARM_MODE=full` for full ordering). Not
covered at first: the kernel writing into such a mapping before the program has (a `read` into it failed with
EFAULT); since 0.4.6 such a call is made again once the range is copied, where an argument points into it (not a
buffer named only through an `iovec`). Mappings of files with a name are copied when they are made, as before.

## 12. fork after the fallback

Found while looking into item 11: `FreezeForFork` keeps the other threads from writing what a forked child copies by
taking their views' write rights; after a fallback to full ordering their translated code writes guest memory
directly, past the views. Done (0.4.5): such a fork holds the other threads with FEX's own signal until the child has
its copy, and a system call that signal interrupted is made again (no EINTR for the program). `tests/forksnap.c`
and `tests/forkeintr.c` after a forced fallback in `tests/ci.sh`.

## 13. i386 programs of glibc 2.35 and older

Found by the release's checks, which build their 32-bit test programs on the runner: on Ubuntu 22.04 every statically
linked i386 program crashed at start-up (the guest jumped to an address FEX would not run), under FEX without the
patches as well, and with FEX linked statically too; a program without a C library (`exit` through `int 0x80`) ran.
The same programs built with Ubuntu 24.04's cross C library (glibc 2.39) ran, and the programs of Ubuntu 22.04 crashed
on the Pi just the same: not the host but the C library.

The i386 C library up to glibc 2.35 makes its system calls through the kernel's entry point that AT_SYSINFO names.
Where FEX has no VDSO to take it from (FEX linked statically, a build without its thunks, `tso-arm run` without
`--gpu`), it makes a page of its own (`int 0x80; ret`): mapped readable and writable, made read-only on the host
alone, so FEX's own tracking knew it as not executable, and FEX does not translate what it knows so. Every such
program died at its first system call. Done (0.4.6): the page is mapped executable for the guest and writable on the
host only while its code goes in. `tests/vsyscall32.c` calls through AT_SYSINFO in `tests/ci.sh`; the release's checks
build their 32-bit programs on Ubuntu 22.04 as well again. A fix for FEX itself.

## 14. Start-up

Every run translated a program's code anew: `python3 -c 0` from the root file system took 0.32 s on the Pi 5, most of
it FEX translating, and short programs run again and again (shell scripts, build tools, `git`) pay it each time. FEX's older code cache crashed (notes section 56). Since the rebase FEX has a new one, its
disk cache (`FEX_DISKCACHE`, off by default in FEX): translated blocks keyed by the guest's code (its file and offset,
or a hash of anonymous code) and FEX's configuration, written by a thread of its own, files locked against other
processes. Without the patches' views it worked as it was: `python3 -c 0` 0.11 instead of 0.33 s, `git --version`
0.045 instead of 0.092 s, zstd's whole run some 3 % faster.

What the page protocol makes of a block depends on more than FEX's configuration: with the views asleep (one thread)
or fallen back to full ordering, guest memory is addressed directly and ordered as configured, alike in every run;
with the views awake, through the views, ordered as this run's profile and faults escalated it, with the exit points
it learned. Done (0.4.6): blocks of the first kind are cached under a key with that state (views on, asleep, fallen
back, exact signals), awake ones are neither looked up nor stored, and an address with a handler of its own (a
function translated ahead of time, a thunk's trampoline) is never taken from the cache. A fork while the cache's
writer thread held its locks would have left them held in the child, which also has no writer thread: the locks are
taken around a fork, and the child reads the cache without writing it (it shares the parent's descriptors and their
file locks). `tso-arm run` turns the cache on, one directory per build of the patches (FEX's own version number does
not change with them), and drops the old build's directory with the first run of a new one; `TSO_ARM_DISKCACHE=0`
runs without it, `tso-arm forget --cache` empties it. Under the page protocol `python3 -c 0` 0.11 instead of 0.32 s;
the litmus tests with the cache warm, under the page protocol and under full ordering, never forbidden. Turned on,
FEX's cache made the translated code slower, in two ways of its own: all of it relocatable (the awake protocol's as
well: pigz 9 % slower), and every 32-bit displacement and many immediates loaded as constants the cache could patch
(xz with one thread 9 % slower). Relocatable code only where the cache may keep it, and no such data masks (a block is
taken only where the guest code is the same): the same speed with the cache as without (notes section 60).
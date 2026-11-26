# Changes

## 0.4.10 (2026-11-26)

A fix that matters for every installation of 0.4.6 to 0.4.9: a program that closes all of its descriptors no longer
gets FEX's disk cache written into its files. Besides, Chromium and programs built on it run under the page protocol,
and Steam keeps FEX's disk cache, runs steamwebhelper with Chromium's sandbox, and comes up to its login window under
the page protocol as well. Install or update with `curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh |
sh`, `tso-arm update`, the release's `.deb` or `.rpm`; the FEX patch changed, so this release brings FEX prebuilt
anew.

- **A program that closes its descriptors no longer gets FEX's cache written into its files.** A program that
  closes every descriptor from 3 up at its start (`close_range`, as bubblewrap and other tools that clean up what
  they inherited do) closed FEX's as well, the disk cache's files among them: files the program opened afterwards got
  their numbers, and FEX's cache writer wrote its translated blocks into them (`tests/closeall.c`: 381 KB in 16 files
  of its own), or, where nothing had the numbers, waited a second for each store when the program ended (47.7 instead
  of 0.4 s; Steam's check of user namespaces stopped there with the cache on). In 0.4.6 to 0.4.9, which keep the
  cache on, `TSO_ARM_DISKCACHE=0` steps around it. FEX's long-lived descriptors (the disk cache's files, the root file
  system's and `/proc`'s directories, the server's socket) are FEX's own now: in its range of descriptors, left out
  of `/proc/self/fd`, and neither `close` nor `close_range` closes them (`tests/closeall.c` in CI, with a cold cache).
- Steam with FEX's disk cache: a program no longer sees FEX's own threads in its `/proc/self/task`. The cache's
  writer is a thread of FEX's in every process, and a program that counts its threads by the links of that
  directory counted it as well; Chromium's zygote, which forks only when it is alone there, stopped at `Check failed:
  IsSingleThreaded`, so `tso-arm steam` ran without the cache. FEX counts its own threads now and leaves them out of
  `stat`, `fstatat` and `statx` of the directory, for 32-bit programs as well; `tso-arm steam` keeps the cache on, and
  Steam's programs start faster from their second run. `tests/singlethread.c` (in CI) counts with all three, with one
  thread and with two.
- User namespaces with FEX's disk cache: Linux lets only a process with one thread enter a new user namespace, and
  the cache's writer made `unshare(CLONE_NEWUSER)` fail with EINVAL (Steam: "Steam now requires user namespaces to be
  enabled"). FEX ends the writer for `unshare` and `setns` into a user namespace and starts a new one after the call
  (`tests/userns.c` in CI).
- **Chromium and programs built on it under the page protocol.** Chromium's allocator reserves 32 GB at its start,
  more than the page protocol's 16 GB guest window holds, and Chromium stopped at once with a breakpoint trap (Google's
  headless shell; Steam's steamwebhelper under the page protocol, Electron programs). A mapping the window has no room
  for now starts the fallback to full ordering and is made outside the window, as without views (`munmap`,
  `mprotect`, `madvise`, `mremap`, forks and self-modifying code in it work as natively), the views of slots without
  a thread go back to the host then (on a 39-bit address space they took three quarters, and Chromium's next
  reservations failed), and the profile keeps the fallback, so later runs start without views. The headless shell
  renders a page with V8 and WebAssembly in its first run under the page protocol as under full ordering (4.4 and
  4.1 s on the Pi 5): `tests/chrome_check.sh` in the Compat workflow, `tests/bigmap.c` in CI. Open: a WebAssembly
  access past its memory ends Chromium's renderer under FEX in every mode (x86 Node.js catches it; notes section
  64). `tests/faultrip.c` (CI) checks what V8's and Java's handlers do with a fault's context.
- Steam, with the fixes above, on GitHub's Arm runner: `tso-arm steam` comes up to its login window with FEX's disk
  cache on (after 5 minutes), and so it does under the page protocol (`TSO_ARM_MODE=tso`, after 7.5) and with
  Chromium's sandbox (after 5), which both showed no window before. `tso-arm steam` runs steamwebhelper with the
  sandbox now, as on an x86 computer (`TSO_ARM_STEAM_SANDBOX=0` turns it off), and keeps full ordering as its default
  for now; `--gpu` still ends Steam early.

## 0.4.9 (2026-11-26)

An RPM package for Fedora and openSUSE, `tso-arm steam` (Steam up to its login window, with FEX's full ordering for
now), and faster starts without the page protocol and for 32-bit programs. Install or update with
`curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`, `tso-arm update`, the
release's `.deb` or `.rpm`; the FEX patch changed, so this release brings FEX prebuilt anew.

- Faster starts without the page protocol and for 32-bit programs: FEX freed the 8 MB it keeps in front of `brk` one
  page at a time at every start (2,048 system calls; a program that ends at once 7.1 instead of 12 ms under full
  ordering), and the disk cache's entries are read rather than mapped, which went through FEX's allocator for 32-bit
  programs (12 instead of 25 ms for one that ends at once). The main stack of a 32-bit program is placed in steps of the
  kernel's guard gap instead of a page at a time (2,560 failing `mmap` calls at every start).

- **An RPM package.** Each release brings `tso-arm-VERSION-1.aarch64.rpm` as well (in `SHA256SUMS` too), for Fedora
  and openSUSE: `sudo dnf install ./tso-arm-VERSION-1.aarch64.rpm`, on openSUSE `sudo zypper install
  --allow-unsigned-rpm ./tso-arm-VERSION-1.aarch64.rpm`. The same files in the same places as the Debian package, and
  its scriptlets run the Debian package's maintainer scripts, so it registers and unregisters x86 programs with
  binfmt_misc alike, goes on in a container, and is not installed over an installation by `tools/get.sh`; removed, it
  takes the root file system for every user along (RPM has no purge). It requires glibc 2.35 or newer, the C++
  libraries of the prebuilt FEX and awk (openSUSE's image comes without), recommends curl and unsquashfs, and
  suggests what `learn` needs. `tools/rpm.sh` builds it from a release package with `rpmbuild` (Ubuntu's `rpm`
  package has it); a workflow builds it with Ubuntu 22.04's and 24.04's, installs, runs and removes it in Fedora's and
  openSUSE Tumbleweed's images, and on the Arm runner itself checks the binfmt_misc registration, an upgrade to a
  newer package and the removal. `tso-arm update`, `uninstall` and `tools/get.sh` name dnf and zypper for it. The
  Debian package's workflow now builds from this commit's files as well where a FEX patch changed since the newest
  release (it took the release's package as it was then, and skipped what needs this commit's `tso-arm`).
- **Steam, up to its login window.** `tso-arm steam` fetches Valve's launcher package (`steam-launcher` from
  repo.steampowered.com, checked against Valve's package index) into `~/.local/share/tso-arm/steam`, without
  installing it into the system, and starts it; Steam puts its client into `~/.local/share/Steam` and updates it from
  Valve's servers as on an x86 computer. On GitHub's Arm runner (Xvfb, no GPU) the bootstrap is unpacked after 30 s,
  the client downloaded and unpacked after 60 s, Steam's runtime container and steamwebhelper (its Chromium) run after
  2.5 minutes, and the "Sign in to Steam" window appears after about 4; `.github/workflows/steam.yml` requires it, with
  screenshots, windows, processes and Steam's logs as an artifact (`tests/steam_check.sh`). Signing in and games are
  not tested. Four things stood in the way under FEX, which `tso-arm steam` steps around for now (docs/GUIDE.md,
  "Steam"): FEX's disk cache writer is a thread of its own in every process, and Chromium's zygote
  forks only when it is alone in `/proc/self/task` (`Check failed: IsSingleThreaded`; `tests/singlethread.c` sees two
  tasks with the cache, one without), so the cache is off; under the page protocol the renderer, GPU and network
  processes the zygote forks ended within seconds (Chromium's way of forking alone, `tests/forkstack.c`, keeps parent
  and child apart under both orderings), so Steam runs with FEX's full ordering; with Chromium's sandbox no window
  came either, so steamwebhelper runs without it; and steamwebhelper's sandboxed zygote, in Steam's runtime container
  and a network namespace of its own, reached neither of FEX's server sockets, so `tso-arm steam` puts the server's
  socket into the home directory (`FEX_SERVERSOCKETPATH`), as Valve's own build of FEX for Steam does.
- `tso-arm userns [allow | remove]`: Steam requires user namespaces (its requirements check runs bubblewrap), which
  AppArmor restricts on Ubuntu 23.10 and newer to programs with a profile of their own, and under tso-arm the program
  that asks is FEX: Steam stopped with "Steam now requires user namespaces to be enabled". `sudo tso-arm userns allow`
  puts an AppArmor profile in place that allows them to tso-arm's FEX alone (as Ubuntu's own profiles do for Chrome and
  others), `remove` takes it away, `tso-arm check` shows the state, and `tso-arm uninstall` removes the profile of its
  installation.
- `tso-arm run` takes scripts (`#!`): FEX runs their interpreter from the root file system (Steam's launcher and
  `steam.sh`, the start scripts of games); it said "not an x86 Linux program" before.
- `tso-arm run` unsets an `XDG_RUNTIME_DIR` that names no writable directory (a session without a login manager,
  another user's after `su`): FEX's server makes a socket there and did not start where it could not, and FEX with it
  ("FEXServerClient: Failure to setup client").

## 0.4.8 (2026-11-26)

A Debian package for Debian, Ubuntu and Raspberry Pi OS, the one-line installer tested on seven distributions, and the
disk cache made to work as meant: programs start about three times as fast from their second run (a static program
that ends at once in 6.5 instead of 16 ms, `python3 -c 0` in 0.095 s). Install or update with
`curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`, `tso-arm update` or the
release's `tso-arm_0.4.8_arm64.deb`; the FEX patch changed, so this release brings FEX prebuilt anew.

- The disk cache keeps the code of the page protocol's awake state as well: a block is taken only where the escalations
  within its range are the ones it was translated with (they go into its guest code's hash), and not while the run has
  learned exit points of its own (rare). zstd starts in 46 instead of 63 ms on the Pi 5; efficiency 87 % (pigz 91, xz
  91, zstd 79 %). Litmus tests with the cache warm, three rounds: none forbidden.
- The disk cache's stores were lost where a program kept every core busy until it ended: FEX's writer thread runs at
  nice 19 and its queue was thrown away at the exit, so zstd -T4 missed 424 of its 714 blocks in every run. The queue is
  written out before `exit_group` and `execve` now; the cache grows in the first run only, and zstd on a small input
  starts in 33 instead of 59 ms. `TSO_DISKCACHE_LOG=1` prints each lookup of the cache with its state and outcome.
- The disk cache stored no block that addressed its own program's data: FEX knew an image's extent only for its older
  code cache, and the cache's relocation filter took such references for addresses outside the image (a static
  program's start missed 91 of 165 blocks in every run). A fault of FEX's own. Now a program that ends at once starts in
  6.5 instead of 16 ms with the cache, zstd on a small input in 19 instead of 59 ms, `python3 -c 0` in 0.095 s.
- **Installing on other distributions.** The one-line installer and a first run are tested on every change in the
  container images of Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04, Fedora and openSUSE Tumbleweed, as root (the
  installation for every user) and as a user: `tso-arm check`, x86-64 and 32-bit programs with their threads and
  litmus tests, `tso-arm report`, `tso-arm uninstall` (`.github/workflows/distros.yml`, `tests/distro_check.sh`;
  docs/GUIDE.md lists what each needs first). The installer names what a system lacks before it fetches anything,
  with the command that installs it there (`apt-get install curl ca-certificates`, `zypper install gawk`, `dnf`,
  `pacman`, `apk`), and after unpacking checks with glibc's dynamic loader that the prebuilt FEX finds its libraries.
  It failed on a system without awk only when a program ran (openSUSE's image: "not an x86 Linux program"), and on
  Alpine at the checksum (BusyBox's `sha256sum` has no `--quiet`) instead of at the C library; it says now that the
  prebuilt FEX needs glibc and that a container of a distribution with glibc runs tso-arm. On Debian 11 and Amazon
  Linux 2023 (glibc 2.31, 2.34) it says that FEX is built from source there. The tests check these messages in
  Alpine's, Debian 11's and Amazon Linux 2023's images.
- The installer finds the newest release through GitHub's release page where GitHub's API refuses (60 requests an
  hour from one address without a token), and says when no CA certificates are installed instead of only that
  GitHub could not be reached. Where binfmt_misc cannot be written (read-only in a container that sees it), the
  installation as root goes on without the registration and says so.
- `tso-arm rootfs` names the command that installs curl and unsquashfs where they are missing (FEX's fetcher said
  only that one of its tools was required); `tso-arm run` says that FEX needs glibc where the shell said "not found".
- `tso-arm check` and `report`: whether FEX starts here (its libraries found, in versions new enough), the C library
  (musl as well; `ldd` is a bash script of glibc's), the cores' part numbers without lscpu, the virtual address bits
  from the kernel's configuration where Fedora keeps it, else from the process's own addresses (in a container), and
  the page size without getconf.
- **A Debian package.** Each release brings `tso-arm_VERSION_arm64.deb` beside its tarballs (and in `SHA256SUMS`), for
  Debian, Ubuntu and Raspberry Pi OS: `sudo apt install ./tso-arm_VERSION_arm64.deb` installs for every user as
  `get.sh | sudo sh` does, into `/opt/tso-arm` with the command as `/usr/bin/tso-arm`, and registers x86 programs
  with binfmt_misc (programs started directly, x86-64 containers); inside a container, where binfmt_misc is not
  available, it says so and installs all the same. `apt remove` unregisters them, `apt purge` removes the root file
  system `sudo tso-arm rootfs` fetched for every user as well. It depends on the C and C++ libraries of the prebuilt
  FEX (glibc 2.35 or newer), recommends curl and squashfs-tools for `tso-arm rootfs` and suggests what `learn` needs.
  It is not installed over an installation by `tools/get.sh` in `/opt/tso-arm` (it says how to remove that one),
  and `tools/get.sh`, `tso-arm update` and `tso-arm uninstall` leave the package's installation to apt.
  `tools/deb.sh` builds it from a release package with `dpkg-deb`; a workflow builds it from the newest release,
  has lintian report on it, and installs, runs, removes and purges it on Ubuntu 22.04 and 24.04 and in a Debian 12
  container.
## 0.4.7 (2026-11-26)

Vulkan programs under `--gpu` work on Wayland desktops, Raspberry Pi OS's own among them, in the default ordering
mode as well. Install or update with `curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`
or `tso-arm update`; the FEX patch changed, so this release brings FEX prebuilt anew.

- `--gpu` on a Wayland desktop (Raspberry Pi OS's own): Vulkan programs that draw in a Wayland window or ask whether
  they could (vulkaninfo) stopped (`Too many bits for size_t`): with the root file system's x86 libwayland the host's
  driver got the program's connection to the compositor and read it as its own. `--gpu` selects FEX's Wayland thunk
  beside the Vulkan one now, so that both sides share the host's libwayland. Two faults stood in its way, one of FEX's
  own: the thunk made the program's read-only interface tables writable with the host's `mprotect`, which the page
  protocol's mapping of a read-only file refuses (`Permission denied`), and now the program makes them writable itself
  first; and the page protocol could not reach the host's memory that a thunk hands a program (a Wayland event's
  arguments, memory a Vulkan driver maps), so such an access sends the program to full ordering now, which addresses
  memory directly, and runs again. On the Pi 5 vulkaninfo reports the V3D presenting to Wayland windows, under the page
  protocol as under full ordering. The graphics check runs vulkaninfo on a headless Weston, with and without `--gpu`.

## 0.4.6 (2026-11-26)

Programs start much faster from their second run on: `tso-arm run` keeps what FEX translated in a cache on disk,
for the patched FEX's own states only, so x86 order stays kept. Vulkan programs that chain a debug messenger, among
them vulkaninfo, run under `--gpu` now, and 32-bit programs of older distributions start. Most of the faults fixed
are FEX's own. Install or update with `curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`
or `tso-arm update`; the FEX patch changed, so this release brings FEX prebuilt anew.

- **A program starts faster the second time.** `tso-arm run` turns on FEX's disk cache: code translated in an
  earlier run of the same program and libraries is loaded instead of translated anew. On a Raspberry Pi 5
  `python3 -c 0` starts in 0.11 instead of 0.32 s, `git --version` in 0.05 instead of 0.09 s. The patched FEX keeps
  only code that every run translates alike (without the page protocol, or with its views asleep or fallen back),
  keyed by that state; code of the awake page protocol depends on what the run shares and is translated anew. A fork
  child reads the cache but does not write it (FEX's cache left its locks to a child that has no writer thread). A
  process whose last thread ends with `exit` alone (a program without a C library, a main thread ended with
  `pthread_exit`) ends with it now, as on Linux: FEX's cache writer thread kept it as a zombie that blocked SIGTERM.
  `tests/lastexit.c`.
  `tso-arm status` shows its size, `tso-arm forget --cache` empties it, `TSO_ARM_DISKCACHE=0` runs without.
  FEX's cache, turned on, made the translated code itself 9 % slower in two ways (relocatable code everywhere, and
  displacements and immediates loaded as patchable constants); neither is left, and the efficiency is 84 to 86 % in two
  sessions (pigz 90 to 92, xz 87 to 89, zstd 77 %), the page protocol alone 74 %.
- i386 programs whose C library makes its system calls through AT_SYSINFO (glibc 2.35 and older: Ubuntu 22.04's, Debian
  11's, older games' runtimes) crashed at their first one where FEX has no VDSO (FEX linked statically, as in
  containers; a build without thunks; `tso-arm run` without `--gpu`): the page FEX makes for that entry was not
  executable in FEX's own tracking. A fault of FEX's own; `tests/vsyscall32.c`, and the release's checks build their
  32-bit test programs on Ubuntu 22.04 again.
- A system call the kernel had to write into a copy-on-write mapping for (a `read` into a section Wine mapped,
  before the program wrote it itself) came back with EFAULT: the range is copied and the call made again now (an
  argument pointing into it; a buffer named only through an `iovec` is not looked at). `tests/cowmap.c` reads from a
  pipe into such a mapping.
- `--gpu`: vulkaninfo stopped with SIGILL, and so did every program that chains a debug messenger into
  `vkCreateInstance` (validation set-ups, engines in debug builds): FEX's Vulkan thunk handed the program's x86
  function to the host's loader, which called it as Arm code. Such structures (debug messengers and reports, a device
  memory report, a list of drivers to load) are taken out of the chain for the call now and put back after it, and a
  messenger a program makes itself gets FEX's host function also where the program took the function that makes it
  from `vkGetInstanceProcAddr` (vulkaninfo does; it went to the loader as it was). Faults of FEX's own;
  `tests/vkproc.c` does both, and the graphics check runs vulkaninfo and it with and without `--gpu`. Still open: on a
  desktop with a Wayland compositor, a Vulkan program that asks about Wayland windows (vulkaninfo does) hands the host's
  driver its x86 `wl_display` (FEX's Wayland thunk is not selected) and stops (`Too many bits for size_t`); without
  a Wayland display vulkaninfo runs through on the Pi's V3D.
- `--gpu`: no line on the terminal any more for each Vulkan function a program looks up that FEX's thunk has no
  signature for (vulkaninfo had ten, DXVK more); the program gets a null pointer for it, as before.
  `TSO_ARM_VULKAN_UNKNOWN=1` prints them.

## 0.4.5 (2026-11-25)

Containers: once installed for every user, `docker run --platform linux/amd64 IMAGE` runs x86-64 images on an Arm
computer with x86's memory order kept. FEX is now its newest commit, and two faults are fixed, one of FEX's own.
Install or update with `curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh` (with
`| sudo sh` for every user, containers included) or `tso-arm update`; the FEX patch changed, so this release brings
FEX prebuilt anew.

- x86-64 containers: `docker run --platform linux/amd64 IMAGE` runs x86-64 images with x86 order kept, once `tso-arm
  binfmt register` has run (the installation for every user does it). It registers a statically linked FEX, built
  beside FEX and in the release package, with binfmt_misc's `F` flag: the kernel starts it in a container as well,
  where it runs the program itself, without FEX's server and on the container's own files; on the host it hands
  programs on to `tso-arm run` as before. `tests/container_check.sh` in CI (Ubuntu 24.04's image: its own programs,
  tso-arm's test programs, 64-bit and 32-bit, `apt-get install python3`).
- A fault of FEX's own, found by the statically linked FEX: its allocator for FEX's memory above a 32-bit program's
  4 GB (and above 47 bits on a host with 48-bit addresses) threw away the first page of whatever mapping followed each
  region it took into use (`madvise(MADV_DONTNEED)` one page too long). In the statically linked FEX that page held
  the main thread's thread-local storage, and FEX crashed at once; in FEX as built before it hit a page of a library
  or the stack, mostly without harm.
- fork in a program whose views fell back to full ordering (its memory kept moving between threads, or more threads
  than view slots): the child copies guest memory after the fork, and the other threads' translated code, which then
  writes past the views, went on writing into what it copied; a lock taken meanwhile came out taken in the child,
  which waited for it forever. The other threads now wait, held by a
  signal of FEX's own, until the child has its copy; a system call that signal interrupted is made again, so the
  program sees no EINTR. `tests/forksnap.c` after a forced fallback: 49 of 50 children saw memory from after the fork,
  now none; `tests/forkeintr.c`: 150 calls came back with EINTR, now none.
- FEX: the patches on FEX 8e980598 (2026-11-24), 44 commits newer than be66e03; FEX moved its synchronous faults
  into its frontend meanwhile.
- `tso-arm check` names the FEX a release package brings along (`fex/prebuilt`), which `tso-arm run` takes, instead
  of "not installed yet" after the one-line installation.
- Windows programs through `tso-arm wine` run under the page protocol now, as every other program (they ran with
  FEX's full ordering): Wine maps wineserver's sections private and writable on purpose and relies on Linux showing
  it what wineserver writes there later; the views copied such a mapping when it was made, so a Wine process kept
  reading the session memory as it was then, explorer.exe got no desktop, started another explorer.exe and waited
  for itself. A writable private mapping of a file without a name now stays the file until its first write, which
  copies it (`tests/cowmap.c`). Two more mapping faults of the views found on the way: a read-only private mapping
  past the file's end was zeros of its own, which never showed what was written there after the file grew
  (`tests/filegrow.c`), and a `MAP_FIXED` mapping over memory another thread had read left that thread's views on
  the old memory (`tests/fixedover.c`). Under the page protocol no explorer.exe is left now, as under full ordering,
  and the ring buffer test passes; `TSO_ARM_MODE=full` gives Wine full ordering.
- CI, the compatibility and the Wine workflows no longer run for commits that change only words; the release's
  checks start x86-64 containers through the package's statically linked FEX.

## 0.4.4 (2026-11-25)

What people run on an Arm computer beyond command-line x86-64 programs: 32-bit programs, AppImages, Windows programs
through Wine, programs with a window and a GPU, installed in one line for one user or for everyone. `docs/GUIDE.md`
is the guide for using it, `docs/ROADMAP.md` lists what was missing and what is still open. Install with
`curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`, or update from 0.4.3 with
`tso-arm install` in a checkout or package of this release. The FEX patch changed, so this release brings FEX
prebuilt anew, now with FEX's thunks.

- 32-bit x86 programs run: `tso-arm run` took only x86-64 programs, and `binfmt register` registered only them. FEX
  orders every access of a 32-bit program itself (the page protocol is for x86-64 programs), as fast as `--mode
  full`; `learn` says it translates x86-64 code only. `litmus/mp32.c` (message passing, vector and string stores,
  load buffering) and a 32-bit `tests/threads.c` in `tests/ci.sh`, and started directly in CI.
- `tso-arm run` no longer needs binutils: it reads a program's machine, kind and build ID itself (with `od` and
  `awk`, from the file's first kilobyte), a few milliseconds faster than three `readelf` calls. Only `learn` needs
  `readelf` still. `tests/elfinfo_check.sh` compares both over a root file system's programs and libraries (1,084
  ELF files, x86-64 and i386: the same).
- On a kernel with 16 or 64 KB pages, `tso-arm check` and `tso-arm install` say what to do: on a Raspberry Pi the
  line in `config.txt` that boots Raspberry Pi OS's 4 KB-page kernel (the Pi 5 starts with a 16 KB one), on Apple
  silicon that x86 programs run in a 4 KB-page virtual machine there.
- Installing in one line: `curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh`
  installs the newest release with FEX prebuilt into `~/.local/share/tso-arm`; with `sudo sh` for every user into
  `/opt/tso-arm`, with x86 programs started directly running through tso-arm. `tso-arm update` brings such an
  installation up to date (never to an older release unless asked), `tso-arm uninstall` removes it. As root in an
  installation for every user, `tso-arm rootfs` fetches one root file system for all of them. `tso-arm run` takes
  the FEX a release package brings along without installing it.
- GPU acceleration, when asked for: the prebuilt FEX now has FEX's thunks, and `tso-arm run --gpu` (or
  `TSO_ARM_THUNKS=1`) sends an x86 program's Vulkan calls to the host's own Vulkan library and GPU driver, and its
  OpenGL through the x86 Mesa's Zink onto the same (FEX's own OpenGL thunk stopped with an X error on an X server).
  On the Pi 5 an x86-64 program reaches the V3D through Vulkan instead of seeing only llvmpipe; on an X server
  `vkcube` draws 200 frames in 1.1 instead of 2.7 s. Off unless asked for, as in FEX: Ubuntu's `vulkaninfo` stops
  with SIGILL through the Vulkan thunk (in every ordering mode), 32-bit programs have no Vulkan thunk.
- Windows programs: `tso-arm wine PROGRAM.exe` runs them through WineHQ's Wine 11 for Ubuntu 24.04, fetched on first
  use (checked against WineHQ's package index). A ring buffer between two Win32 threads: 20 million messages, all
  right with x86 order kept, 351,869 wrong without ordering. The Wine workflow runs it on GitHub's Arm runner. Wine runs
  with FEX's full ordering by default for now: under the page protocol some of its processes (explorer.exe started
  without a display) are left waiting on a lock of the guest's C library (`TSO_ARM_MODE=tso` tries it).
- Fixed in FEX, found with Wine: memory mapped with `PROT_WRITE` or `PROT_EXEC` alone is readable on x86, and the
  page protocol took reads of it for faults of the program's own (wineserver stopped at its start); a segment
  register load (`mov %eax, %ds`) read the descriptor from FEX's own table through the views (every Windows program
  stopped with "nested exception on signal stack"). `tests/writeonly.c` and `tests/segload.c` in `tests/ci.sh`.
- Fixed in FEX, found with Wine: a fork of a program with several threads gave the child memory its parent's other
  threads wrote after the fork (the page protocol copies the child's memory after the fork, and a thread writes its
  own pages without a fault): a lock another thread took just after the fork came out taken in the child, which
  waited for it forever. The other threads' writes now wait while the child copies.
  `tests/forksnap.c`: 49 of 50 children saw memory from after the fork, now none in 16,000 forks on GitHub's N2.
- `TSO_ARM_MODE` sets the ordering mode for programs started without `--mode` (started directly, through `tso-arm
  wine`).
- Fixed in FEX: a prebuilt FEX unpacked elsewhere than the prefix it was built for did not find its own data
  directory (application configs, the thunks' database and libraries); it now takes the one beside its programs.
  The Vulkan thunk no longer prints a line for every function an application looks up.
- AppImages run: `tso-arm run` unpacks them instead of mounting them (the root file system has no `fusermount`).
  The official `appimagetool` AppImage runs on the Pi 5 and builds an AppImage itself.
- `tso-arm report [PROGRAM ARGS]` gathers what a bug report needs into one block to paste; the issue template on
  GitHub asks for it.
- An empty `XDG_CONFIG_HOME` or `XDG_DATA_HOME` counts as unset: FEX took it as set, looked for its configuration in
  `/fex-emu/`, and its server did not start.

## 0.4.3 (2026-11-22)

Programs started from scripts and test runners no longer wait for FEX's server: a shell command substitution with
`tso-arm run` ends with the program instead of a second later, and `go test -exec` with tso-arm runs Go's standard
library. Update from 0.4.2. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install`
replaces the one of 0.4.2 or older.

- Fixed in FEX: the FEXServer a program starts kept that program's stdin, stdout and stderr and every other
  descriptor it had open, and outlived it. A parent waiting for the end of such a pipe waited for the server: a
  shell's command substitution with `tso-arm run` about a second each time (`tests/ci.sh` 86 s, now 17 s), `go test
  -exec` two minutes and more while other tests kept the server alive. The server starts with them on /dev/null and
  the rest closed (a test in `tests/ci.sh`).
- `tso-arm status PROGRAM` names for each of its profiles what its runs do: the page protocol, full ordering (its
  threads share too much), or pages moving between its threads (`learn` found it faster), and how many code ranges
  run ordered.
- `tests/fork.c`: the child of a process with threads waits up to 2 s for the thread it starts to count, instead of
  10 ms, and a failure names the child's status. On a loaded machine without a profile the thread took longer to
  start (1 run in 20 while Go's tests ran beside it; 40 of 40 right with the wait).

## 0.4.2 (2026-11-22)

A fault of a program's own reaches it with its own address under the page protocol (Go's tests pass with the views),
and `tso-arm learn` lets a program that hands its data between threads move its pages instead of ordering them where
that is faster: zstd 77 % instead of 70 %, efficiency 85 %. Update from 0.4.1. The FEX patch changed, so this release
brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.4.1 or older.

- Fixed in FEX: a fault of the program's own through the page protocol's views (an address it never mapped, a page
  it protected, past the end of a file it mapped) reached it with the address in the view instead of its own
  (0x6000000000 for a nil pointer). Go's runtime compares it with the address it dereferenced and took its own nil
  pointer panics for fatal faults: `go test` failed in sync/atomic, runtime/debug and time once these ran with the
  views. SIGSEGV and SIGBUS name the program's address now (`tests/faultaddr.c` in `tests/ci.sh`).
- `tso-arm learn`: a program that falls back to full ordering is timed with migratory ownership as well, where a page
  another thread writes moves to that thread instead of becoming shared (aot/stage.py); where that is more than 3 %
  faster, its profile says `migrate` and `tso-arm run` uses it. zstd, translated ahead of time, 656 instead of 721
  ms at 1.8 GHz (median of 12); Node, CPython and sort are slower with it and keep full ordering (notes section 55).
  With migration, full ordering comes when the faults hold the protocol's lock for more than 900 per mille of the
  time in three windows of 1,000 faults in a row (`TSO_VIEWS_HELD`). `TSO_VIEWS_MIGRATE=1` migrates for one run,
  `=0` not even where the profile says so.
- A change of hands within 3 ms of the one before counts as quick (was 1 ms; `TSO_VIEWS_QUICK`): fewer pages move
  back and forth.
- Translated code: an unaligned ordered store follows `dmb ishst` instead of `dmb ish`; every earlier load is
  ordered before it already. 1 to 2 % fewer cycles for zstd in full ordering; `AOT_STFULL=1` builds the old barrier.
- Fixed in FEX: a read or write past the end of a file a program mapped shared, under the page protocol, raised
  SIGBUS while FEX completed the access in its fault handler, under the protocol's lock; a handler of the program's
  that left by `siglongjmp` kept the lock, and the next fault of any thread waited forever. FEX checks first whether
  the access can be made and lets the instruction fault where it belongs otherwise.
- Fixed in FEX: processes of one program that ended at the same time wrote their profiles through the same
  temporary file.
- README: efficiency 85 % (pigz 92, xz 88, zstd 77 %), the configuration with translated functions measured as
  `tso-arm learn` leaves a program.
- `TSO_VIEWS_STATS`: the protocol's `mprotect` calls by cause (chunks moving, single pages, stale views, ranges
  coming into a view).
- `litmus/run_views.sh`, `litmus/run_aot.sh`: `FEXV` names the FEX to test, `VIEWS_ENV` adds protocol settings to
  the protocol's runs.

## 0.4.1 (2026-11-22)

A crash with signals sent from outside fixed, and the check for held-back signals made cheaper. Update from 0.4.0.
The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.4.0 or
older.

- The check at every block entry and branch back for a signal held back is a load instead of a store: no slot in the
  store buffer, pigz as FEX translates it 1.30 instead of 1.32 s (notes section 54).
- Fixed in FEX: FEX's handler for SIGSEGV ran with SIGSEGV blocked (taken from the guest's action), and a fault of
  FEX's own in it ended the process: the store at the end of a signal-deferring section to the interrupt page that a
  signal sent meanwhile by another thread had armed (`tests/sigsync.c` on GitHub's N2, 6 of 60 runs without a
  profile), or a fault of the page protocol while FEX wrote a guest frame. It runs with SIGSEGV open now.

## 0.4.0 (2026-11-22)

Asynchronous signals reach a program at an instruction start, and Go's preemption works: Go programs run with it
on, and Go's own tests under `go test` pass with it. Update from 0.3.11. The FEX patch changed, so this release
brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.11 or older.

- Fixed in FEX: a signal sent to a program (not a fault of its own) that came in while translated code, FEX's
  dispatcher or FEX's own helpers ran was delivered at once, with the state of the middle of an instruction's
  translation, or the state in memory while the registers were live elsewhere. A handler that resumes the thread
  elsewhere took that state for the truth: Go programs crashed or computed wrong results with Go's asynchronous
  preemption, under FEX without the patches as well. Such a signal now goes back into the kernel's queue, blocked
  until the thread's next block entry, branch back or system call, where the kernel delivers it with the state of
  an instruction start (notes section 54); `TSO_EXACT_SIGNALS=0` turns it off. The checks cost about 4 % in pigz's
  loops as FEX translates them, nothing measurable with the hot functions translated ahead of time (which deliver a
  signal at once, as before).
- Fixed in FEX: a signal FEX deferred in a handler and delivered after the handler had returned put the handler's
  signal mask back for good, and a signal the handler blocked was never delivered again.
- Fixed in FEX: SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE sent by another thread or process in quick succession
  (FEX leaves them open in its handlers, for faults of its own) were delivered to the program from inside FEX's
  handler, whose stack then ran the program's handler, and the next ones nested deeper until that stack ran out and
  the process crashed. They wait for the thread's next check now. During a translation FEX queued every such
  signal, past the room it reserved, and grew the queue inside the signal handler while handlers nested in it read
  it: a signal of a number that waits already merges with it now, and the queue never grows.
- `tso-arm run` no longer turns Go's preemption off (`GODEBUG=asyncpreemptoff=1`, still so with
  `TSO_EXACT_SIGNALS=0`); goroutines in long loops without calls are preempted again.
- `tests/preempt.c` (in `tests/ci.sh`): a handler that makes the interrupted thread call a routine at the
  interrupted address, as Go's preemption does, many times a second.
- `tests/sigspin.c` (in `tests/ci.sh`): a loop that waits for its signal handler, also with the loop translated
  ahead of time, where a signal is still delivered at once; and a loop of register arithmetic in Go's layout, during
  which a timer's signal must come in.
- `tests/sigsync.c` (in `tests/ci.sh`): SIGSEGV, SIGBUS, SIGILL, SIGTRAP and SIGFPE sent by another thread to a
  running loop, also without pauses between them.
- README: efficiency measured with these patches, 83 % (pigz 91, xz 88, zstd 70 %).

## 0.3.11 (2026-11-21)

Programs started under nohup keep SIGHUP ignored. Update from 0.3.10. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.10 or older.

- Fixed in FEX: a program started with a signal ignored (nohup's SIGHUP; execve keeps it ignored) saw that signal
  at its default instead. A Go program under nohup installed its handler for SIGHUP and died of the hangup nohup was
  there to keep away. FEX takes such signals as ignored for the program now (notes section 53).
- `tests/sigign.c` (in `tests/ci.sh`): signals ignored across execve.
- The patches apply to FEX's newest commit again (an include next to one FEX added).
- Go's own tests (go1.27.4, 20 packages): the same results under tso-arm and under FEX's full ordering.
- `tests/rootfs_check.sh` and `tests/soak.sh` start their programs with SIGPIPE at its default (GitHub's runner
  ignores it), and `tests/compat.sh` takes a crash without x86 order for what that mode shows.

## 0.3.10 (2026-11-21)

A thread no longer waits for good in code another thread patched. Update from 0.3.9. The FEX patch changed, so this
release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.9 or older.

- Fixed in FEX: a thread could stay in the translation of code that another thread had overwritten. FEX's block
  linker looked up a branch's target, let go of its lock, and linked the branch after it took the lock again; when
  another thread's store threw the target away in between, the link pointed to the old translation and nothing
  undid it. A `jmp .` (which HotSpot writes over a method's entry for a moment while it patches five bytes) then
  waited there for good. The linker links to the translation the block list holds now (none: through the
  dispatcher), and a jump to itself leaves its block through a linked exit (notes section 52).
- `tests/xmc.c` patches through a `jmp .` as well (`xmc N loop`, in `tests/ci.sh`).

## 0.3.9 (2026-11-21)

Java no longer crashes now and then. Update from 0.3.8. The FEX patch changed, so this release brings FEX prebuilt
anew; `tso-arm install` replaces the one of 0.3.8 or older.

- Fixed in FEX: code another thread wrote while FEX translated it could stay translated as it was before the write,
  or as a mix of old and new bytes. FEX protected a page of guest code against writes only after it had translated
  from it; a store in between went unseen. A JIT that patches a method's entry while another thread runs into it
  was concerned: HotSpot (Java) crashed now and then, under FEX without the patches as well (4 of 80 runs). The page
  is protected before its bytes are read now, and a store waits until the translation is done and throws it away
  (notes section 52): no crash in 260 runs since.
- `tests/xmc.c` (in `tests/ci.sh`): a function patched two bytes at a time while another thread calls it; under FEX
  without the patches every run crashed.
- `tests/ci.sh` takes the test programs' exit status: a pipe into `tail` had passed one that crashed or reported a
  failure only by its status (the litmus tests report a forbidden outcome so).

## 0.3.8 (2026-11-21)

What CPython's whole test suite found with the views throughout (no fallback by fault rate). Update from 0.3.7.
The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.7 or
older.

- Fixed: a thread sent back to the dispatcher at an instruction start could go on with a guest register already set
  for a later instruction. FEX shares a constant within a block, and its register allocator put a 0 into rcx where
  the 0 was first made, before the store ahead of the `xor %ecx, %ecx` that wanted it; repeated from its start, the
  store wrote to address 8 (CPython's garbage collector unlinking an object, about one run of `test_import` in ten
  crashed; notes section 51). Constants are not shared across such instruction starts now.
- Fixed: with nearly all of a program's descriptors in use, a `vfork` (Python's `subprocess`) closed one of the
  program's own. The views took two descriptors for a pipe at every fork, which left none for FEX's pipe for vfork,
  and FEX then closed whatever numbers its pair held. A fork under the views needs no descriptor now (a word in
  shared memory and a futex), nor does FEX's vfork under the views or without a descriptor left.
- Fixed: a program could start only about a hundred threads under the views on a 39-bit address space (the
  Raspberry Pi 5's kernel): the views reserved 13 slots, 416 of its 512 GB, and FEX took some 700 MB of address
  space per thread. Now 300: the views leave a quarter to the host (11 slots there, all 15 on 48 bits), FEX's
  allocator gives back the half of each 256 MB span it only mapped for the alignment, and each thread's lookup
  cache covers the views' 16 GB window instead of 64 GB. Beyond that the program gets EAGAIN for a new thread
  instead of FEX dying.
- `TSO_VIEWS_LOG=/path` writes the views' log to a file (a vfork child logging into a pipe its waiting parent reads
  stopped both); `TSO_VIEWS_SLOTS` lowers the number of view slots.
- `tests/exactstart.c` and `tests/fdfull.c` (in `tests/ci.sh`): the unlink from CPython at a thread's exit to the
  dispatcher, and fork, vfork and posix_spawn's clone with 0 to 10 descriptors left.

## 0.3.7 (2026-11-21)

Self-modifying code under the views: a multithreaded program that wrote over code it had run could keep running
the old code. Update from 0.3.6. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install`
replaces the one of 0.3.6 or older.

- Fixed: code that a multithreaded program wrote over while it ran under the views kept running in its old
  translation (FEX protects the pages it translated from against writes only where FEX itself addresses guest
  memory, not in the views the translated code writes through; notes section 50). A JIT that reuses or patches its
  code was concerned, HotSpot made FEX crash at once when the protocol did not fall back. No view writes such a page
  now before FEX has seen the store and thrown the translations away.
- `tests/smc.c` (in `tests/ci.sh`): code rewritten while a second thread runs, and code written by one thread for
  another.

## 0.3.6 (2026-11-21)

FEX's own file descriptors stay out of a program's way, and `fexecve` works. Update from 0.3.5. The FEX patch
changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.5 or older.

- Fixed in FEX: its own descriptors (its server's socket, the root file system's directory and others) took the
  lowest free numbers, so a program started with its standard input closed read FEX's socket as stdin, a program
  run after a `posix_spawn` that closed descriptor 0 got its own executable as stdin, and a child could find and write
  into FEX's socket on a number it had not inherited. They live just below the limit on open files now, and the
  socket is hidden from `/proc/self/fd` like the others (notes section 49).
- Fixed in FEX: a program started with `fexecve` saw its arguments shifted by one (its `argv[0]` went).

## 0.3.5 (2026-11-21)

Go programs run. Nothing changed in the FEX patch: update from 0.3.4 by fetching this tso-arm; FEX stays.

- Go programs run: Go's runtime preempts goroutines with a signal and resumes them with the state its handler saw,
  which FEX does not give exactly in the middle of translated code (Go programs crashed within a second, under FEX
  without the patches as well; notes section 48). `tso-arm run` turns that preemption off
  (`GODEBUG=asyncpreemptoff=1`; `TSO_ARM_GO_PREEMPT=1` keeps it); goroutines stop at Go's own safe points then.
- `tests/compat.sh` runs a Go program as well (goroutines, channels, a mutex, and message passing through
  sync/atomic that only x86 order keeps right).

## 0.3.4 (2026-11-21)

Single-threaded programs run without the views, and signal delivery fixed: a thread that got a signal during a
system call could crash in its handler, and two faults of FEX's own crashed CPython's `test_signal`. Update from
0.3.3. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.3
or older.

- A process with a single thread runs without views and without ordering until a second thread starts or it maps
  memory shared with another process (notes section 46). Most commands never get there: a program start costs what
  it does under FEX (40.9 against 46.8 ms), and Ubuntu's gzip, bzip2 and openssl run at 84, 75 and 68 % of the
  host's builds with the page protocol (were 79, 70 and 59 %); the distribution table's mean with learned functions
  83 instead of 80 %. `TSO_VIEWS_ASLEEP=0` starts with the views awake.
- `tests/wake.c` (in `tests/ci.sh`): code translated while the views slept does not run on with two threads.
- Fixed: a thread that got a signal during a system call could go on in its handler with registers of the
  interrupted code (its stack pointer among them) and crash, under the views whenever the handler met memory that
  another thread uses (notes section 47). FEX left the handler its "in a system call" state, and the page
  protocol's exits from a block then spilled none of the handler's registers.
- Fixed in FEX's signal delivery (FEX without the patches crashes in both, CPython's `test_signal` too): a signal
  that came in while another thread changed its action could take the handler of one action and the checks of
  the other (a guest jumping to address 1); a second signal during FEX's handler for the first ran FEX's handler
  inside it and lost the first one's frame. The action is now read as a whole, and FEX's handler runs with every
  signal blocked that it does not need itself.
- Fixed: the layer for translated libraries wrote its notes to the program's standard error, which belongs to the
  program (a test that wants it empty failed); now only on a terminal or with `TSO_AOT_LOG`. It also finds room for
  its stubs next to more libraries (every 2 MiB within branch range instead of four places).
- `tso-arm run` says so when FEX's server, which a program still running started, serves another root file system
  than `FEX_ROOTFS` names: FEX takes the root file system from its server.
- `tests/sigrace.c` (in `tests/ci.sh`): two signals at once, and one raised while another thread changes its
  action. `tests/cpython_suite.sh`: CPython's own tests of threads, signals, fork, queues and memory maps (750
  cases) against FEX's full ordering, case by case. `tests/compat.sh` runs Java as well (a parallel sort, a
  concurrent map, and message passing that only x86 order keeps right).

## 0.3.3 (2026-11-20)

Programs with large libraries start faster and need much less memory. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.2 or older.

- Programs with large libraries start faster and need much less memory: code and read-only data of a program and its
  libraries are mapped from their files instead of copied into every process (notes section 45). `ffmpeg -version`
  0.26 instead of 0.56 s and 93 instead of 266 MB, `node -e 0` 121 instead of 216 MB; a program start 46.8 instead
  of 50.5 ms (FEX's full TSO: 40.6 ms).
- `madvise(MADV_DONTNEED)` on a read-only private file mapping: its pages read the file again afterwards, not zeros.
- `tests/filemap.c` (in `tests/ci.sh`): private file mappings under the views behave as private ones.

## 0.3.2 (2026-11-20)

A crash fix, and programs with large functions much faster (ffmpeg, Node). Update from 0.3.1: a thread could die of
a segmentation fault there. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install`
replaces the one of 0.3.1 or older.

- Programs with large functions much faster: `tso-arm` has FEX compile multiblock units of at most 150 guest
  instructions (`FEX_MAXINST`, FEX's default 5000), so a function entered at many points is no longer compiled whole
  again from each (notes section 43). ffmpeg with x264 1.7 instead of 2.9 s, its first run 2.4 instead of 5.3 s;
  Node 5.0 instead of 8.2 s; both now faster than FEX without any ordering. Set `FEX_MAXINST` to override.
- Fixed: a thread could die of a segmentation fault (git's `pack-objects` with 4 threads, about 1 run in 5 when FEX
  compiled block by block, as it does with translated libraries). It had run into a boundary trap at the start of a
  guest jump, and before its fault handler read the trap, another thread linked the jump to its target over it; the
  handler now recognizes that case (notes section 44).
- `tests/rootfs_check.sh` also packs a git repository with 4 threads, runs make with 4 jobs and rsync.

## 0.3.1 (2026-11-20)

Faster code under the page protocol, and a profile that forgets one run's accident. Ubuntu's programs (xz, gzip,
bzip2, openssl) at 80 % of the host's own Arm builds instead of 78 %, openssl now ahead of FEX's full TSO. The FEX
patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.3.0 or older.

- Faster translated code under the page protocol: the full guest state is written back only at the instruction
  starts where a thread can leave its block (accesses to memory, control flow, block ends), no longer at every
  instruction (notes section 42). The views' cost for openssl's sha512 went from 31 to 13 %, for xz from 14 to 9 %;
  pigz ahead of time 92 instead of 90 %.
- The page protocol's profile no longer takes one run's accident for good: after a program's first run, a code range
  that met shared memory enters the profile only when it does so again in the next run that changes the profile
  (notes section 41). One run of Ubuntu's xz with 4 threads had added 801 ranges that every later run then ordered
  (1.4 instead of 1.26 s).
- Fixed: with `XDG_CACHE_HOME` set, FEX kept the page protocol's profiles in `~/.cache/tso-arm` anyway, so
  `tso-arm status` and `forget` did not see them; they go to `$XDG_CACHE_HOME/tso-arm` now, beside what `learn` keeps.

## 0.3.0 (2026-11-20)

Programs as distributions ship them: `tso-arm learn` translates the hot functions of a program's shared libraries
as well. And a fix for 0.2.3's vfork, which programs that start others with Python's subprocess hit: update from
0.2.3. The FEX patch changed, so this release brings FEX prebuilt anew; `tso-arm install` replaces the one of 0.2.3
or older.

- **Shared libraries ahead of time.** `learn` splits its profile between the program and the shared libraries it
  runs and translates the hot functions of each, with the functions they call. A shared library's translation is
  kept under the library's name and build ID and serves every program that maps that library; what several programs
  learned in one library is merged. FEX takes it when the guest maps the library and gives it up when the guest
  unmaps it (dlclose). Ubuntu's xz, whose work is all in liblzma, runs at 96 % of the host's own Arm xz on the Pi
  with one thread (31.0 s against 36.9 s without the translation), 86 % with four.
- `bench/distro.sh` measures programs of the root file system (xz, gzip, bzip2, openssl) against the host's own Arm
  builds: 78 % in the geometric mean with what `learn` translated, against 61 % under FEX's full TSO; the table is
  in the README.
- `learn` times each variant with a page protocol profile of its own: one shared profile grows from run to run and
  made the later runs slower, which once had it leave out a library that made xz 30 % faster.
- Fixed (from 0.2.3): the parent of a vfork could go on while its child still ran on the parent's memory, when the
  child closed all its descriptors before execve, as Python's subprocess does; both then ran on one stack (a wrong
  byte in the child's output, or `FileNotFoundError` for a program that exists). The kernel now holds the parent
  until the child has called execve or exited.
- Fixed: `aot/elfsyms.py` missed functions without a stack frame in stripped programs and libraries (their unwind
  entry has no instructions of its own), so their callers went back into the guest for them.
- A program started with execve no longer checks the library `tso-arm run` named for its parent against its code
  (one message per function); it looks its own up.
- `tso-arm status PROGRAM` lists the shared libraries learned for it.

## 0.2.3 (2026-11-20)

Shells and programs with signal handlers. The FEX patch changed, so this release brings FEX prebuilt anew;
`tso-arm install` replaces the one of 0.2.2 or older.

- Fixed: a signal handler of the program crashed FEX, in every mode and since 0.1.0 (bash reaping a child, a timer,
  `raise`). The handler's stack overwrote the host state FEX had saved at the signal.
- Fixed: a process forked without calling execve (bash's command substitution `$(...)`, pipelines, shell scripts,
  Python's multiprocessing) went on sharing the memory that is private for the program with its parent: under the
  page protocol that memory is shared memory, mapped again into the views. Parent and child wrote into each other's
  stacks and heaps and one of them crashed. The child gets its own copy of the writable memory now, made while the
  parent waits; read-only memory stays shared until either side makes it writable, memory the program mapped shared
  stays shared, and a vfork child runs on its parent's memory as the program asked (so `posix_spawn` of a missing
  program reports the error). A fork costs about 1 ms more on the Pi (2.8 against 1.8 ms), plus the copy of a large
  heap.
- Fixed: x87 arithmetic (`long double`) could crash under the page protocol (Ubuntu's `seq`): FEX's accesses to the
  x87 registers in the thread's context went through the views.
- `tests/fork.c`, `tests/signals.c` and `tests/x87.c` run in the CI; `tests/rootfs_check.sh` compares 25 everyday
  commands of the root file system (shells, coreutils, compression, perl, Python with fork and signals) with FEX's
  full ordering.

## 0.2.2 (2026-11-20)

Programs of an x86-64 root file system learn from their earlier runs. The FEX patch changed, so this release brings
FEX prebuilt anew; `tso-arm install` replaces the one of 0.2.0 or 0.2.1.

- Fixed: programs of an x86-64 root file system (dynamically linked ones) got no page protocol profile, or one bound
  to a host program of the same path, so their later runs did not start from what the first had learned. On
  GitHub's Neoverse N2, ffmpeg went from 2.8 s to 1.7 s (FEX's full TSO: 1.7 s) and Node from 6.1 s to 5.2 s (5.1 s).
- `tso-arm rootfs` without options fetches Ubuntu 24.04 without questions.

## 0.2.1 (2026-11-20)

Dynamically linked programs right after `tso-arm rootfs`, and x86-64 programs started directly. FEX and its patches
are the same as in 0.2.0.

- Fixed: after `tso-arm rootfs`, dynamically linked programs were refused, since `tso-arm` looked for FEX's setting
  in `~/.fex-emu` only; it reads it where FEX does (`~/.config/fex-emu` when `~/.fex-emu` does not exist). Checked
  with Ubuntu 24.04 from FEX's server: x86-64 `bash`, `python3` and `sort` run, `sort` with the Arm `sort`'s output.
- `tso-arm binfmt [register | unregister]`: x86-64 programs started directly (`./program`) run through tso-arm, for
  the whole system and after a reboot (needs root); checked in the CI.
- `tests/transitions.sh` measures what a call across the border of translated code costs (on the Pi 40 ns inward,
  81 ns outward), which is why `learn` leaves out libraries of programs that cross it all the time.

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

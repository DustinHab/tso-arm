# Using tso-arm

tso-arm runs x86 Linux programs (64-bit and 32-bit) on a 64-bit Arm computer: a Raspberry Pi 5, an Arm laptop or
server, a Rockchip board. This page is for using it; the README says how it works and how fast it is.

## Installing

On 64-bit Arm Linux with 4 KB pages (Ubuntu 22.04 and newer, Debian 12 and newer, Raspberry Pi OS):

```sh
curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sh
```

That installs the newest release for you, FEX included, in a few seconds; nothing is compiled. The command lands in
`~/.local/bin` (log in again if your shell does not find `tso-arm` yet).

For every user of the computer instead, and so that x86 programs start like any other program (`./program`, a
double click in a file manager):

```sh
curl -fsSL https://raw.githubusercontent.com/DustinHab/tso-arm/main/tools/get.sh | sudo sh
```

**Raspberry Pi 5 with Raspberry Pi OS:** the Pi 5 starts a kernel with 16 KB pages, which FEX cannot use. The 4 KB
kernel is on the card already; one line selects it:

```sh
echo kernel=kernel8.img | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

`tso-arm check` tells whether a computer can run tso-arm, and what to change if not.

## Running programs

```sh
tso-arm rootfs                  # once: the x86 libraries most programs need (Ubuntu 24.04, about 2 GB)
tso-arm run ./program args...   # an x86 program, as it would run on an x86 computer
```

- Programs linked statically (a single file without libraries) run without `tso-arm rootfs`.
- Programs that need libraries take them from the root file system `tso-arm rootfs` fetched: the x86-64 and 32-bit
  libraries of Ubuntu 24.04, among them X11, Wayland, OpenGL, Vulkan, SDL, GTK and Qt libraries. Installed for every
  user, `sudo tso-arm rootfs` fetches one for all of them.
- **AppImages** run as they are: `tso-arm run ./App.AppImage`.
- **32-bit programs** run too, a little slower than 64-bit ones (every memory access is ordered for them).
- With the installation for every user (or `sudo tso-arm binfmt register`), x86 programs start directly:
  `./program`, from scripts, from a file manager.

## Graphics

x86 programs draw with the x86 graphics libraries of the root file system. On many Arm boards those have no driver
for the GPU and draw with the processor: it works, but slowly. `--gpu` sends a program's OpenGL and Vulkan calls to
the computer's own libraries and its GPU driver instead:

```sh
tso-arm run --gpu ./game
```

Vulkan goes through FEX's thunk to the computer's own Vulkan driver, OpenGL through Mesa's Zink (OpenGL on Vulkan)
onto the same: on a Raspberry Pi 5 an x86 program's OpenGL then runs on the Pi's GPU (`zink Vulkan 1.3(V3D 7.1…)`).
It covers much but not all of Vulkan: try a program with and without `--gpu`. OpenGL in a window needs an X server
with DRI3 (desktops have it, Wayland's Xwayland too; Xvfb and some VNC servers do not): without it, leave `--gpu`
off, or Vulkan programs only. 32-bit programs keep drawing with the x86 Mesa (FEX has no 32-bit Vulkan thunk). To have it for
programs started directly, set `TSO_ARM_THUNKS=1` in the environment (for example in `~/.profile`); `TSO_ARM_MODE`
does the same for the ordering mode.

## Faster: learn

```sh
tso-arm learn ./program args...
```

`learn` runs the program a few times with these arguments, translates its busiest functions ahead of time, checks
them, and keeps them if the program is faster with them. Give it arguments whose work has no side effects (it runs
the program several times). It needs `sudo apt install binutils python3 python3-capstone clang linux-perf`.
`tso-arm status PROGRAM` shows what it learned, `tso-arm forget PROGRAM` drops it.

## When a program does not run

1. `tso-arm check`: can this computer run tso-arm at all?
2. Is it an x86 Linux program? `tso-arm run` says so when it is not (Windows programs need Wine, below).
3. "needs an x86-64 root file system": run `tso-arm rootfs` once.
4. Try `tso-arm run --mode full ./program`. If it runs that way and not without, that is a fault in tso-arm: please
   report it. If it fails both ways, it is most likely a limit of FEX, which tso-arm is built on.
5. With `--gpu`: try without it.

To report a problem, open an issue on GitHub with the output of

```sh
tso-arm report ./program args...
```

It lists the versions, the computer and what tso-arm knows of the program, and runs the program once in each
ordering mode (stdin empty, output discarded), so give it arguments that change nothing.

## Windows programs

```sh
tso-arm rootfs                  # once, if not done yet
tso-arm wine setup.exe          # a Windows program; the first time fetches Wine (about 240 MB)
tso-arm wine notepad            # Wine's own programs as well: winecfg, regedit, ...
```

`tso-arm wine` runs Windows programs through Wine, WineHQ's own build for Ubuntu 24.04 (the distribution of the
root file system), which it fetches from WineHQ the first time and keeps in `~/.local/share/tso-arm/wine`; `tso-arm
wine install` fetches a newer one. The Windows "C:" drive and settings are in `~/.wine` as usual (`WINEPREFIX` for
another). Windows programs need x86's memory order between their threads just as Linux programs do: the tests run
one that passes data between two threads without locks, 20 million messages, all of them right with tso-arm and some
hundred thousand wrong without ordering. `tso-arm wine` keeps that order with FEX's full ordering for now
(`TSO_ARM_MODE=tso` tries the page protocol, which still leaves some of Wine's processes waiting).

## Containers

With the installation for every user (or `sudo tso-arm binfmt register`), x86-64 container images run as well:

```sh
docker run --rm --platform linux/amd64 ubuntu:24.04 uname -m     # x86_64
```

Docker and Podman start a container's programs through the kernel, which hands x86 ones to tso-arm's statically
linked FEX: it needs nothing of the computer's own files inside the container, and it keeps x86's memory order as
`tso-arm run` does (`-e TSO_ARM_MODE=full` or `unordered` picks another mode), 32-bit programs as well. `tso-arm
binfmt` says whether containers are covered. Not in containers: `--gpu`, and what `learn` translated (both need the
computer's own files). If QEMU was registered for x86 programs as well (Docker Desktop's
`binfmt` image, `qemu-user-static`), the one registered last is used: `tso-arm binfmt` names it, and `sudo tso-arm
binfmt register` puts tso-arm last again.

## Keeping it up to date

```sh
tso-arm update          # sudo tso-arm update for the installation for every user
tso-arm uninstall       # removes it again (--all: what learn translated as well)
```

## Ordering modes

x86 programs that run several threads rely on x86's memory order. tso-arm keeps it by default, and pays for it only
where threads really share memory.

| Mode | What it is for |
|---|---|
| `tso` (default) | x86's order where threads share memory, nothing elsewhere |
| `full` | every access ordered, as FEX does it: the reference when something looks wrong |
| `unordered` | no ordering at all: fastest, but programs whose threads share data without locks can go wrong |

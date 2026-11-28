# Using tso-arm

tso-arm runs x86 Linux programs (64-bit and 32-bit) on a 64-bit Arm computer: a Raspberry Pi 5, an Arm laptop or
server, a Rockchip board. This page is for using it; the README says how it works and how fast it is.

## Installing

On 64-bit Arm Linux with 4 KB pages and glibc 2.35 or newer (Ubuntu 22.04 and newer, Debian 12 and newer, Fedora,
openSUSE Tumbleweed, Raspberry Pi OS; the list below says what each needs first):

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

**As a Debian package** (Debian, Ubuntu, Raspberry Pi OS; releases from 0.4.8 on): download
`tso-arm_VERSION_arm64.deb` from the [releases](https://github.com/DustinHab/tso-arm/releases) and install it with
apt, which fetches the libraries it needs:

```sh
sudo apt install ./tso-arm_0.4.8_arm64.deb      # the version downloaded
```

It installs for every user as the line with `sudo` does: into `/opt/tso-arm`, the command as `/usr/bin/tso-arm`, and
x86 programs and x86-64 containers start directly. Inside a container, where the kernel's binfmt_misc is not
available, it says so and installs all the same; `tso-arm run` works there. `sudo TSO_ARM_BINFMT=0 apt install ...`
leaves programs started directly as they are. The package is not installed over an installation by the line with
`sudo`: `sudo tso-arm uninstall` removes that one first.

**As an RPM package** (Fedora, openSUSE; releases from 0.4.8 on): download `tso-arm-VERSION-1.aarch64.rpm` from the
[releases](https://github.com/DustinHab/tso-arm/releases) and install it with dnf or zypper (the package is not
signed, hence zypper's option):

```sh
sudo dnf install ./tso-arm-0.4.8-1.aarch64.rpm                               # Fedora
sudo zypper install --allow-unsigned-rpm ./tso-arm-0.4.8-1.aarch64.rpm       # openSUSE
```

It installs the same files in the same places as the Debian package and does the same at installation, in a
container as well, and with an installation by the line with `sudo`.

**Raspberry Pi 5 with Raspberry Pi OS:** the Pi 5 starts a kernel with 16 KB pages, which FEX cannot use. The 4 KB
kernel is on the card already; one line selects it:

```sh
echo kernel=kernel8.img | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

`tso-arm check` tells whether a computer can run tso-arm, and what to change if not.

### Distributions

The installer names what a system lacks, with the command that installs it there, before it fetches anything. These
distributions are tested on every change (`.github/workflows/distros.yml`), from their own container images, which
come with less than an installed system; what each needs before the one-line install:

| Distribution | Before the installer |
|---|---|
| Debian 12 and 13, Raspberry Pi OS | `sudo apt-get install curl ca-certificates` (where curl is missing) |
| Ubuntu 22.04, 24.04 and 26.04 | `sudo apt-get install curl ca-certificates` (where curl is missing) |
| Fedora | nothing |
| openSUSE Tumbleweed | `sudo zypper install gawk` (where awk is missing) |
| Alpine (musl) | does not run there: the prebuilt FEX needs glibc. A container of a distribution with glibc (`podman run -it debian:13`) runs tso-arm |
| Debian 11, Amazon Linux 2023 (glibc 2.31, 2.34; RHEL 9 and its rebuilds have 2.34 as well) | the prebuilt FEX needs glibc 2.35 or newer: FEX is built from source there (`tso-arm install --source` in a clone of the repository) |

In each, as root and as a user, the tests install, run `tso-arm check`, x86-64 and 32-bit programs with their threads
and litmus tests, `tso-arm report` and `tso-arm uninstall`. `tso-arm rootfs` needs curl and unsquashfs as well
(`squashfs-tools`, on openSUSE `squashfs`), which it names where they are missing.

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
- **32-bit programs** run too, a little slower than 64-bit ones (every memory access is ordered for them;
  `TSO_ARM_32_VIEWS=1` tries the page protocol on one, which is no faster on the whole yet).
- **Chromium and programs built on it** (Electron programs, Steam's windows) run as well: Google's headless Chrome
  renders pages under tso-arm in all modes. They reserve more memory than the page protocol's window holds and run
  with FEX's full ordering, from their first start on (tso-arm knows them by V8's snapshot or CEF beside the
  program; `--mode tso` tries the page protocol, which falls back at once). Chromium's sandbox works, seccomp-bpf included (FEX emulates its filters); it needs user namespaces (see
  Steam below), and `--no-sandbox` runs without it.
- With the installation for every user (or `sudo tso-arm binfmt register`), x86 programs start directly:
  `./program`, from scripts, from a file manager.
- **The second start is faster.** FEX keeps the code it translated in a cache on disk (`~/.cache/tso-arm/fex`), and a
  later run of the same program and libraries loads it instead of translating it again: on a Raspberry Pi 5
  `python3 -c 0` starts in 0.095 instead of 0.32 s, `git --version` in 0.035 instead of 0.09 s, Chrome's headless
  shell renders a page in 1.6 instead of 4.8 s. Processes a program forks keep what they translate as well (Chromium's
  renderers, a shell's subshells). `tso-arm status` shows the cache's size, `tso-arm forget --cache` empties it,
  `TSO_ARM_DISKCACHE=0` runs without it.

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
off, or Vulkan programs only. Vulkan programs draw in X11 windows and, on a Wayland desktop (Raspberry Pi OS's own),
in Wayland windows: `--gpu` sends a program's Wayland calls to the computer's own libwayland as well. A program that
meets the computer's own memory that way runs with FEX's full ordering, as `--mode full` would. 32-bit programs keep drawing with the x86 Mesa (FEX has no 32-bit Vulkan thunk). To have it for
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
hundred thousand wrong without ordering. `tso-arm wine` keeps that order with the page protocol, as `tso-arm run`
does; if a Windows program misbehaves, try `TSO_ARM_MODE=full tso-arm wine program.exe` (FEX's full ordering) and
report it if that helps.

## Desktop programs without an Arm build

```sh
tso-arm rootfs                  # once, if not done yet
tso-arm app install spotify     # by name: chrome, discord, edge, signal, slack, spotify, zoom
tso-arm app install ./some-program_amd64.deb    # or any x86 Debian package, a file or an https address
tso-arm app list                # what is installed so
tso-arm app run spotify         # or its entry in the desktop's menu
tso-arm app remove spotify
```

Programs whose makers ship Linux builds for x86 only (Discord, Spotify, Slack, Signal, Zoom, Microsoft Edge, and
many others) come as Debian packages. `tso-arm app install` fetches one from its maker's own address (by name, for
the programs above; a package index's entry is checked against the index's checksum), puts its files into the root
file system of `tso-arm rootfs` (FEX lays that over `/` for x86 programs, so the program finds itself where its
package put it: `/opt/zoom`, `/usr/lib/slack`), fetches the libraries it needs that the root file system lacks from
Ubuntu 24.04's archive (checked against Ubuntu's signed index), and adds an entry to the desktop's menu that starts it
through tso-arm. It replaces no file the root file system has, lists every file it adds, and `remove` takes exactly
those away again; the package's own install scripts do not run, and it updates by installing again (Discord and others
update themselves). A root file system installed for every user is not writable for a user: `tso-arm rootfs` fetches
one of your own.

Chromium and Electron programs (Discord, Slack, Signal, Spotify's player, Edge) run in their own sandbox, as they do
natively: their renderers in user, PID and network namespaces of their own, without access to your files, and under
seccomp-bpf filters, which FEX emulates. That needs user namespaces: on Ubuntu 23.10 and newer, where AppArmor
restricts them, `sudo tso-arm userns allow` allows them to tso-arm's FEX alone. Where they are not allowed, the
programs start with `--no-sandbox` and run without that protection (unpacked, their setuid sandbox helper has no root
rights); `TSO_ARM_APP_SANDBOX=0` or `1` decides instead. They reserve more address
space than the page protocol's window holds and run with FEX's full ordering from their start. Discord's package
holds only a starter, which fetches Discord into `~/.config/discord` on its first start (its setup window); from then
on `tso-arm app run discord` starts Discord itself. What the tests cover: each of the six programs installed and
started on GitHub's Arm runner until its window draws (`.github/workflows/apps.yml`, weekly, with screenshots):
Discord, Spotify, Signal, Slack, Zoom and Edge draw their windows (Zoom after some two minutes). Signing in and using
them is not tested. A limit a program sets on its own data or address space (Chromium's renderers: 8 GB of data) is
kept by FEX for the program and not set on the host, where it would count FEX's own memory as well; it is read back
as set but not enforced.

## Steam

```sh
tso-arm rootfs                  # once, if not done yet
sudo tso-arm userns allow       # once, on Ubuntu 23.10 and newer (below)
tso-arm steam                   # Valve's Steam client; the first time fetches Valve's launcher and the client
```

`tso-arm steam` fetches Valve's own launcher package (`steam-launcher` from repo.steampowered.com, checked against
Valve's package index) into `~/.local/share/tso-arm/steam`, without installing it into the system, and starts it;
Steam then puts its client into `~/.local/share/Steam` and keeps it up to date as on an x86 computer. Measured on
GitHub's Arm runner (4 Neoverse N2 cores, an X server without a screen, no GPU; `.github/workflows/steam.yml`): the
bootstrap after 30 s, the client downloaded and unpacked after 60 s, Steam's runtime container and steamwebhelper
(the Chromium that draws Steam's windows) after 2.5 minutes, the "Sign in to Steam" window after about 4 minutes.
Signing in and games are not tested yet.

**User namespaces.** Steam does not start without them ("Steam now requires user namespaces to be enabled"). Ubuntu
23.10 and newer let AppArmor restrict them to programs with a profile of their own, and under tso-arm the program
that asks is FEX: `sudo tso-arm userns allow` puts a profile in place that allows them to tso-arm's FEX alone,
`tso-arm userns` shows the state, `sudo tso-arm userns remove` takes it away. Lifting the restriction for every
program (`sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0`) works as well.

**What `tso-arm steam` sets, and why.** Steam's windows come from steamwebhelper, which forks its renderer, GPU and
network processes from a "zygote". `tso-arm steam` sets:

- FEX's full ordering (`TSO_ARM_MODE=full`): up to 0.4.9 the processes the zygote forks ended within seconds under
  the page protocol (Chromium reserves more address space than the protocol's window held). Since 0.4.10 Steam comes
  up to its login window under the page protocol as well, in its first start some two minutes later than under full
  ordering (on GitHub's runner 7.5 instead of 5 minutes); full ordering stays the default for now. Games started from
  Steam inherit it: they run correctly, but with every access ordered (as `--mode full`).
- Chromium's sandbox for steamwebhelper is on, as on an x86 computer (up to 0.4.10 `tso-arm steam` turned it off,
  as no window came with it before 0.4.10); `TSO_ARM_STEAM_SANDBOX=0` turns it off (`-cef-disable-sandbox`).
- FEX's server socket in the home directory: steamwebhelper runs in Steam's runtime container, which has a runtime
  directory of its own, and FEX did not reach its server there ("Couldn't connect to FEXServer socket").

Each of these can be set otherwise for trying (`TSO_ARM_MODE=tso tso-arm steam`, `TSO_ARM_STEAM_SANDBOX=0`). Not working yet: `--gpu` (`TSO_ARM_THUNKS=1 tso-arm steam`): zenity's progress windows
crashed, the 32-bit client stopped at `surface_linux.cpp (2002): Fatal assert`, steamwebhelper's GPU process with a
segmentation fault, and Steam ended after 5.5 minutes. Steam started with `tso-arm steam` waits for other x86
programs that run through tso-arm to end (one FEX server per user).

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

The Debian package is updated by a newer release's package (`sudo apt install ./tso-arm_VERSION_arm64.deb`) and
removed with `sudo apt remove tso-arm`; `sudo apt purge tso-arm` removes the root file system `sudo tso-arm rootfs`
fetched for every user as well. The RPM package is updated the same way (`sudo dnf install
./tso-arm-VERSION-1.aarch64.rpm`, on openSUSE `sudo zypper install --allow-unsigned-rpm ...`), and `sudo dnf remove
tso-arm` (`sudo zypper remove tso-arm`) removes it together with that root file system: RPM has no purge of its own.
What `learn` translated stays in each user's `~/.cache/tso-arm`.

## Ordering modes

x86 programs that run several threads rely on x86's memory order. tso-arm keeps it by default, and pays for it only
where threads really share memory.

| Mode | What it is for |
|---|---|
| `tso` (default) | x86's order where threads share memory, nothing elsewhere |
| `full` | every access ordered, as FEX does it: the reference when something looks wrong |
| `unordered` | no ordering at all: fastest, but programs whose threads share data without locks can go wrong |

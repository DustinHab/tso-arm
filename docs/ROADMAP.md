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
| 4 | GPU acceleration for x86 programs (FEX's thunks) | open |
| 5 | Installing for every user, in one line, and updating | open |
| 6 | Containers: `docker run --platform linux/amd64` | open |
| 7 | Windows programs through Wine, AppImages, programs with a window: tested | open |
| 8 | The page protocol for 32-bit programs | open |
| 9 | A guide for users: what runs, what to do when something does not | open |

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

## 5. Installing for every user, and updating

`tso-arm install` installs into the home directory of whoever runs it; `binfmt register` then points the whole system
at a program in that home directory. Installing needs git or a downloaded package, and there is no way to update to a
newer release but doing it again.

## 6. Containers

On Arm servers and laptops, x86-64 container images run through binfmt_misc with an emulator registered with the
`F` flag, so that it is found inside the container's own file system. That needs an interpreter without a dynamic
loader of its own: FEX is dynamically linked against the host's libraries.

## 7. Wider tests

CI runs command-line programs from x86-64 Ubuntu (sort, 7-Zip, Python, ffmpeg, Node, Java, Go, git, make). Not yet:
Wine with a Windows program, an AppImage, a program with an X11 window.

## 8. The page protocol for 32-bit programs

32-bit programs run with FEX's full ordering (item 1). The views would need 4 GB windows per thread instead of 16 GB
and the translated code's 32-bit addresses based on them.

## 9. A guide for users

The README describes the mechanism and its measurements. A user needs: what runs (and how fast), the commands for
the common cases, and what to do when a program does not run (`tso-arm check`, `--mode full`, what to report).

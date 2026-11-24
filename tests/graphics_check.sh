#!/bin/sh
# Programs with a window, on the X server in DISPLAY (CI: Xvfb), from the root file system 'tso-arm rootfs' fetched:
# glxinfo and glxgears (OpenGL through GLX), vkcube (Vulkan through XCB), with the x86 Mesa of the root file system and
# with --gpu (Vulkan through FEX's thunk to the host's library, OpenGL through the x86 Mesa's Zink onto it). The
# renderer string says which one drew: llvmpipe with 256-bit vectors is the x86 Mesa (AVX2), 128 the host's on Arm,
# "zink" OpenGL on Vulkan. FEX's own OpenGL thunk is tried as well, for information.
#   tests/graphics_check.sh [ROOTFS]     exit status 1 if OpenGL or Vulkan fails with the x86 Mesa or with --gpu
cd "$(dirname "$0")/.."
T=$PWD/bin/tso-arm
R=${1:-$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04}
[ -n "$DISPLAY" ] || { echo "graphics_check: no X server (DISPLAY)"; exit 2; }
gl=$(mktemp)
printf '{ "ThunksDB": { "GL": 1 } }\n' >$gl
fail=0
# check NAME REQUIRED RUN-ARGS...: glxinfo, glxgears, vkcube
check() {
    name=$1 req=$2
    shift 2
    out=$(timeout 120 "$@" $R/usr/bin/glxinfo -B 2>&1)
    r=$(printf '%s\n' "$out" | sed -n 's/^OpenGL renderer string: //p')
    if [ -n "$r" ]; then
        echo "ok:   $name: glxinfo: $r, OpenGL $(printf '%s\n' "$out" | sed -n 's/^OpenGL version string: \([0-9.]*\).*/\1/p')"
    else
        echo "$req: $name: glxinfo: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')"
        [ "$req" = FAIL ] && fail=1
    fi
    out=$(timeout 12 "$@" $R/usr/bin/glxgears 2>&1)
    f=$(printf '%s\n' "$out" | grep -m1 'frames in')
    if [ -n "$f" ]; then
        echo "ok:   $name: glxgears: $f"
    else
        echo "$req: $name: glxgears: $(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')"
        [ "$req" = FAIL ] && fail=1
    fi
    s=$(date +%s%N)
    st=0
    out=$(timeout 120 "$@" $R/usr/bin/vkcube --c 200 2>&1) || st=$?
    ms=$((($(date +%s%N) - s) / 1000000))
    if [ $st = 0 ]; then
        echo "ok:   $name: vkcube, 200 frames in $ms ms"
    else
        echo "$req: $name: vkcube: exit status $st: $(printf '%s\n' "$out" | grep -v 'Unknown Vulkan' | tail -n 2 | tr '\n' ' ')"
        [ "$req" = FAIL ] && fail=1
    fi
}
check "x86 Mesa" FAIL $T run
check "--gpu" FAIL $T run --gpu
check "FEX's OpenGL thunk" "info" env TSO_ARM_THUNKS=1 FEX_THUNKCONFIG=$gl MESA_LOADER_DRIVER_OVERRIDE= $T run
rm -f $gl
exit $fail

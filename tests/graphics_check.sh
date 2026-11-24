#!/bin/sh
# Programs with a window, on the X server in DISPLAY (CI: Xvfb), from the root file system 'tso-arm rootfs' fetched:
# glxinfo and glxgears (OpenGL through GLX), vkcube (Vulkan through XCB), each with the x86 Mesa of the root file
# system and with --gpu (FEX's thunks: the host's own libraries). The renderer string says which one drew: llvmpipe
# with 256-bit vectors is the x86 Mesa (AVX2), with 128 the host's on Arm.
#   tests/graphics_check.sh [ROOTFS]     exit status 1 if OpenGL fails either way
cd "$(dirname "$0")/.."
T=bin/tso-arm
R=${1:-$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04}
[ -n "$DISPLAY" ] || { echo "graphics_check: no X server (DISPLAY)"; exit 2; }
fail=0
for gpu in "" --gpu; do
    name=${gpu:-"x86 Mesa"}
    out=$(timeout 120 $T run $gpu $R/usr/bin/glxinfo -B 2>&1)
    r=$(printf '%s\n' "$out" | sed -n 's/^OpenGL renderer string: //p')
    if [ -n "$r" ]; then
        echo "ok:   $name: glxinfo: $r, OpenGL $(printf '%s\n' "$out" | sed -n 's/^OpenGL version string: \([0-9.]*\).*/\1/p')"
    else
        echo "FAIL: $name: glxinfo: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
        fail=1
    fi
    out=$(timeout 12 $T run $gpu $R/usr/bin/glxgears 2>&1)
    f=$(printf '%s\n' "$out" | grep -m1 'frames in')
    if [ -n "$f" ]; then
        echo "ok:   $name: glxgears: $f"
    else
        echo "FAIL: $name: glxgears: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
        fail=1
    fi
    s=$(date +%s%N)
    st=0
    out=$(timeout 120 $T run $gpu $R/usr/bin/vkcube --c 200 2>&1) || st=$?
    ms=$((($(date +%s%N) - s) / 1000000))
    echo "      $name: vkcube, 200 frames: exit status $st in $ms ms$( [ $st = 0 ] || printf ': %s' "$(printf '%s\n' "$out" | grep -v '^Unknown\|Unknown Vulkan' | tail -n 2 | tr '\n' ' ')")"
done
exit $fail

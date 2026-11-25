#!/bin/sh
# Graphics of x86 programs from the root file system 'tso-arm rootfs' fetched, with the x86 Mesa of the root file
# system and with --gpu (Vulkan through FEX's thunk to the host's library, OpenGL through the x86 Mesa's Zink onto it):
# OpenGL and Vulkan without a window (eglinfo with EGL surfaceless, vulkaninfo --summary, tests/vkproc.c), and on the X
# server in DISPLAY (CI: Xvfb) glxinfo and glxgears (OpenGL through GLX) and vkcube (Vulkan through XCB). The renderer says which one drew: llvmpipe with 256-bit
# vectors is the x86 Mesa (AVX2), with 128 the host's on Arm, "zink" OpenGL on Vulkan. Zink's window path needs DRI3,
# which Xvfb has not, so OpenGL in a window under --gpu is for information there; FEX's own OpenGL thunk as well.
#   tests/graphics_check.sh [ROOTFS]     exit status 1 if a required check fails
cd "$(dirname "$0")/.."
T=$PWD/bin/tso-arm
R=${1:-$HOME/.local/share/fex-emu/RootFS/Ubuntu_24_04}
gl=$(mktemp)
printf '{ "ThunksDB": { "GL": 1 } }\n' >$gl
fail=0
say() { # REQUIRED NAME WHAT RESULT-OR-EMPTY ERROR
    if [ -n "$4" ]; then
        echo "ok:   $2: $3: $4"
    else
        echo "$1: $2: $3: $5"
        [ "$1" = FAIL ] && fail=1
    fi
}
# Vulkan as vulkaninfo starts it, with a debug messenger chained into vkCreateInstance (tests/vkproc.c), where an
# x86-64 compiler is at hand
vkproc=
if command -v x86_64-linux-gnu-gcc >/dev/null 2>&1; then
    vkproc=$(mktemp -d)/vkproc
    x86_64-linux-gnu-gcc -O2 -o $vkproc tests/vkproc.c -ldl || vkproc=
fi
# check NAME REQ-EGL REQ-GLX REQ-VK RUN-ARGS...
check() {
    name=$1 regl=$2 rglx=$3 rvk=$4
    shift 4
    out=$(EGL_PLATFORM=surfaceless timeout 120 "$@" $R/usr/bin/eglinfo -p surfaceless 2>&1)
    say $regl "$name" "eglinfo, no window" "$(printf '%s\n' "$out" | sed -n 's/^OpenGL \(core\|compatibility\) profile renderer: //p' | head -n 1)" \
        "$(printf '%s\n' "$out" | grep -v '^ ' | tail -n 2 | tr '\n' ' ')"
    # Vulkan without a window: vulkaninfo, and the messenger's function, which the host must not call as its own
    st=0
    out=$(timeout 120 "$@" $R/usr/bin/vulkaninfo --summary 2>&1) || st=$?
    say $rvk "$name" "vulkaninfo --summary" "$([ $st = 0 ] && printf '%s\n' "$out" | sed -n 's/^[[:space:]]*deviceName[[:space:]]*= //p' | tr '\n' ';')" \
        "exit status $st: $(printf '%s\n' "$out" | grep -v 'Unknown Vulkan' | tail -n 2 | tr '\n' ' ')"
    if [ -n "$vkproc" ]; then
        st=0
        out=$(timeout 120 "$@" $vkproc 2>&1) || st=$?
        say $rvk "$name" "Vulkan with a debug messenger in vkCreateInstance" "$([ $st = 0 ] && printf '%s\n' "$out" | sed -n 's/^vkproc: \(.* devices through .*\)/\1/p')" \
            "exit status $st: $(printf '%s\n' "$out" | grep -v 'Unknown Vulkan' | tail -n 2 | tr '\n' ' ')"
    fi
    [ -n "$DISPLAY" ] || return 0
    out=$(timeout 120 "$@" $R/usr/bin/glxinfo -B 2>&1)
    say $rglx "$name" glxinfo "$(printf '%s\n' "$out" | sed -n 's/^OpenGL renderer string: //p')" "$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')"
    out=$(timeout 12 "$@" $R/usr/bin/glxgears 2>&1)
    say $rglx "$name" glxgears "$(printf '%s\n' "$out" | grep -m1 'frames in')" "$(printf '%s\n' "$out" | tail -n 2 | tr '\n' ' ')"
    s=$(date +%s%N)
    st=0
    out=$(timeout 120 "$@" $R/usr/bin/vkcube --c 200 2>&1) || st=$?
    ms=$((($(date +%s%N) - s) / 1000000))
    say $rvk "$name" "vkcube, 200 frames" "$([ $st = 0 ] && echo "$ms ms")" \
        "exit status $st: $(printf '%s\n' "$out" | grep -v 'Unknown Vulkan' | tail -n 2 | tr '\n' ' ')"
}
check "x86 Mesa" FAIL FAIL FAIL $T run
# without a GPU (GitHub's runners) Zink passes over the host's CPU device (lavapipe) unless told to take it: then
# OpenGL under --gpu draws with Zink on the host's llvmpipe (128 bits), which shows the path through the Vulkan thunk
if ls /dev/dri/renderD* >/dev/null 2>&1; then
    check "--gpu" FAIL info FAIL $T run --gpu
else
    check "--gpu (no GPU here: Zink on the host's CPU device)" FAIL info FAIL env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=zink $T run --gpu
fi
case $(EGL_PLATFORM=surfaceless timeout 120 env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=zink $T run --gpu $R/usr/bin/eglinfo -p surfaceless 2>&1 |
    sed -n 's/^OpenGL \(core\|compatibility\) profile renderer: //p' | head -n 1) in
*zink*) echo "ok:   --gpu: OpenGL through Zink and the Vulkan thunk" ;;
*) echo "FAIL: --gpu: OpenGL did not go through Zink" && fail=1 ;;
esac
check "FEX's OpenGL thunk" info info info env TSO_ARM_THUNKS=1 FEX_THUNKCONFIG=$gl MESA_LOADER_DRIVER_OVERRIDE= $T run
rm -f $gl
exit $fail

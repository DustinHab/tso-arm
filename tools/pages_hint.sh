#!/bin/sh
# What to do on a kernel without 4 KB pages, which FEX and the views need (tso-arm check and install print it).
# Prints nothing on a 4 KB-page kernel. --size: the page size alone, in bytes.
# getconf (glibc's, musl's), else the kernel's AT_PAGESZ (6) in this process's auxiliary vector
ps=$(getconf PAGESIZE 2>/dev/null || getconf PAGE_SIZE 2>/dev/null) || ps=""
[ -n "$ps" ] || ps=$(od -An -v -tu8 /proc/self/auxv 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) a[n++] = $i } END { for (i = 0; i + 1 < n; i += 2) if (a[i] == 6) print a[i + 1] }')
if [ "$1" = --size ]; then
    echo "$ps"
    exit 0
fi
[ "$ps" = 4096 ] && exit 0
if [ -z "$ps" ]; then
    echo "The page size of this kernel could not be read (getconf PAGESIZE); FEX, and with it tso-arm, needs 4 KB pages."
    exit 1
fi
model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)
echo "This kernel uses $((ps / 1024)) KB pages; FEX, and with it tso-arm, needs a kernel with 4 KB pages."
case $model in
*"Raspberry Pi"*)
    cfg=/boot/firmware/config.txt
    [ -f $cfg ] || cfg=/boot/config.txt
    echo "Raspberry Pi OS boots the Pi 5 with a 16 KB-page kernel and has its 4 KB-page kernel on the card as well."
    echo "To boot that one, add this line at the end of $cfg (under [all]) and reboot:"
    echo
    echo "    kernel=kernel8.img"
    echo
    echo "for example: echo kernel=kernel8.img | sudo tee -a $cfg && sudo reboot"
    ;;
*Apple*)
    echo "Linux on Apple silicon (Asahi) runs with 16 KB pages, which the hardware there requires; x86 programs run"
    echo "there in a small 4 KB-page virtual machine (muvm with FEX), which tso-arm does not set up."
    ;;
*)
    echo "Distributions for most Arm boards and servers build their kernels with 4 KB pages; this one was built with"
    echo "CONFIG_ARM64_$((ps / 1024))K_PAGES. A kernel package with 4 KB pages (CONFIG_ARM64_4K_PAGES) is needed."
    ;;
esac
exit 1

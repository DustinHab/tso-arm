#!/bin/sh
# Fixes the clock of all cores for measurements, or restores the normal setting.
#   tools/freq.sh fix [kHz]    default 1800000
#   tools/freq.sh restore      schedutil, 1.5 to 2.4 GHz
set -e
mode=${1:-fix}
khz=${2:-1800000}
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    if [ "$mode" = restore ]; then
        echo schedutil | sudo tee $c/scaling_governor >/dev/null
        echo 1500000 | sudo tee $c/scaling_min_freq >/dev/null
        echo 2400000 | sudo tee $c/scaling_max_freq >/dev/null
    else
        echo performance | sudo tee $c/scaling_governor >/dev/null
        # Lower the minimum first when going down, raise the maximum first when going up.
        cur=$(cat $c/scaling_max_freq)
        if [ "$khz" -lt "$cur" ]; then
            echo $khz | sudo tee $c/scaling_min_freq >/dev/null
            echo $khz | sudo tee $c/scaling_max_freq >/dev/null
        else
            echo $khz | sudo tee $c/scaling_max_freq >/dev/null
            echo $khz | sudo tee $c/scaling_min_freq >/dev/null
        fi
    fi
done
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
vcgencmd measure_temp

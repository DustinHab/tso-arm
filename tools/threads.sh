#!/bin/sh
# Test machine: the threads of running FEX processes with their state, wait channel and user/system ticks, to see
# where a hung run stands.
#   tools/threads.sh
for p in $(pgrep -x FEX); do
    echo "== $p $(tr '\0' ' ' </proc/$p/cmdline | cut -c1-120)"
    for t in $(ls /proc/$p/task); do
        s=$(cat /proc/$p/task/$t/stat)
        echo "$t $(echo $s | cut -d' ' -f3) utime $(echo $s | cut -d' ' -f14) stime $(echo $s | cut -d' ' -f15) $(cat /proc/$p/task/$t/wchan)"
    done
done

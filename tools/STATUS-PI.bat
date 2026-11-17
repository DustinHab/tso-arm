@echo off
title tso-arm: Pi 5
:loop
cls
echo tso-arm  Pi 5  %date% %time%
echo.
ssh.exe -o ConnectTimeout=5 pi5 "uptime; vcgencmd measure_temp; vcgencmd get_throttled; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq; echo; ps -eo pid,pcpu,etime,comm --sort=-pcpu | head -6; echo; tail -n 18 ~/tso-arm/out/build_translators.log 2>/dev/null"
timeout /t 5 /nobreak >nul
goto loop

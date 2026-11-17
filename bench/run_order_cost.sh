#!/bin/sh
# Builds and runs bench/order_cost.c at a fixed clock; result in out/order_cost.txt.
set -e
cd "$(dirname "$0")/.."
mkdir -p build out
gcc -O2 -mcpu=cortex-a76 -o build/order_cost bench/order_cost.c
trap 'sh tools/freq.sh restore >/dev/null' EXIT
sh tools/freq.sh fix ${KHZ:-1800000}
./build/order_cost ${CPU:-3} | tee out/order_cost.txt
vcgencmd measure_temp
vcgencmd get_throttled

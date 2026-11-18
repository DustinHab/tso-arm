#!/bin/sh
# Test machine: translates the functions of aot/lists/WORKLOAD.list (chosen by aot/auto.sh from a profile) ahead of
# time, with glibc's string functions as units, and builds the library FEX loads with TSO_AOT=out/aot/WORKLOAD.so.
#   aot/build_lib.sh WORKLOAD
#   ORDERED="--ordered NAME..." (functions that start ordered), STRINGS (default --strings), CFLAGS (aot/build.sh)
cd "$(dirname "$0")/.."
w=$1
mkdir -p out/aot
[ -f aot/lists/$w.list ] || { echo "no aot/lists/$w.list (aot/auto.sh $w writes it)"; exit 1; }
python3 aot/lift.py build/x86/$w out/aot/$w.c $(cat aot/lists/$w.list) \
    ${STRINGS:---strings} $(sh aot/strings_specs.sh build/x86/$w) $ORDERED || exit 1
sh aot/build.sh out/aot/$w.c out/aot/$w.so

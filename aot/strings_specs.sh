#!/bin/sh
# The glibc string functions of a static x86-64 binary as aot/lift.py region specs (NAME=ENTRY:START:END): memmove
# and mempcpy, memset, with and without ERMS (FEX reports ERMS or not depending on its TSO settings, and glibc picks
# by it). The variants of a family share one body and jump into each other, so each entry is lifted over the whole.
#   aot/strings_specs.sh BINARY
B=$1
nm -nS "$B" | awk '
    function hex(s,   i, v) { v = 0; s = tolower(s); for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return v }
    $3 ~ /^[tT]$/ { a[$4] = hex($1); z[$4] = hex($2) }
    END {
        lo = a["__mempcpy_avx_unaligned"]; hi = a["__memmove_avx_unaligned_erms"] + z["__memmove_avx_unaligned_erms"]
        if (lo && hi > lo) {
            n = split("__mempcpy_avx_unaligned __memmove_avx_unaligned __mempcpy_avx_unaligned_erms __memmove_avx_unaligned_erms", e, " ")
            for (i = 1; i <= n; i++) if (a[e[i]]) printf "%s=%x:%x:%x\n", e[i], a[e[i]], lo, hi
        }
        lo = a["__memset_avx2_unaligned"]; hi = a["__memset_avx2_unaligned_erms"] + z["__memset_avx2_unaligned_erms"]
        if (lo && hi > lo) {
            n = split("__memset_avx2_unaligned __memset_avx2_unaligned_erms", e, " ")
            for (i = 1; i <= n; i++) if (a[e[i]]) printf "%s=%x:%x:%x\n", e[i], a[e[i]], lo, hi
        }
    }'

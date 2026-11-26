# The data of a Debian package, for tools/wine.sh and tools/steam.sh (sourced): undeb PACKAGE.deb DIR unpacks its
# data.tar.* into DIR, with dpkg-deb where there is one, else read by hand (an ar archive: headers of 60 bytes, name
# 16, dates and ids 32, size 10, end 2; members start at even offsets)
undeb() {
    if command -v dpkg-deb >/dev/null; then
        dpkg-deb -x "$1" "$2"
        return
    fi
    off=8
    total=$(wc -c <"$1")
    while [ $off -lt $total ]; do
        h=$(tail -c +$((off + 1)) "$1" | head -c 60)
        name=$(printf '%s' "$h" | cut -c1-16 | tr -d ' /')
        size=$(printf '%s' "$h" | cut -c49-58 | tr -d ' ')
        case $name in
        data.tar.xz) tail -c +$((off + 61)) "$1" | head -c $size | xz -dc | tar -C "$2" -xf - ;;
        data.tar.zst) tail -c +$((off + 61)) "$1" | head -c $size | zstd -dcq | tar -C "$2" -xf - ;;
        data.tar.gz) tail -c +$((off + 61)) "$1" | head -c $size | gzip -dc | tar -C "$2" -xf - ;;
        esac
        off=$((off + 60 + size + size % 2))
    done
}

# the newest version of package $2 in the index $1 (or the one beginning with $3): VERSION FILENAME SHA256
pick() {
    awk -v p="$2" -v v="$3" '
    /^Package: / { pkg = $2 } /^Version: / { ver = $2 } /^Filename: / { file = $2 } /^SHA256: / { sum = $2 }
    /^$/ { if (pkg == p && (v == "" || index(ver, v) == 1)) print ver, file, sum; pkg = "" }
    END { if (pkg == p && (v == "" || index(ver, v) == 1)) print ver, file, sum }' "$1" | sort -V | tail -n 1
}

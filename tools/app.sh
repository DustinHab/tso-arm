#!/bin/sh
# x86 programs from their makers' Debian packages (what 'tso-arm app' runs): Google Chrome, Discord, Spotify, Slack,
# Signal, Zoom, Microsoft Edge and others that have no Arm build for Linux. The package's files go into the root file system of
# 'tso-arm rootfs', where FEX lays them over / for x86 programs, so the absolute paths a program uses (/opt/zoom,
# /usr/lib/slack) are there; files the root file system has already are never replaced, and every file added is
# listed for 'remove'. The libraries the package depends on that the root file system lacks come from Ubuntu 24.04's
# archive (the root file system's distribution), checked against its index and that against its signed InRelease. A
# menu entry starts the program through tso-arm. The package's own install scripts do not run.
#   tools/app.sh install NAME | PACKAGE.deb | https://URL   install (again): one it knows by name (chrome, discord,
#                                         edge, signal, slack, spotify, zoom: from their makers), a package file or an address
#   tools/app.sh list                                 what is installed so
#   tools/app.sh run NAME [ARGS...]                   start one, as its menu entry does
#   tools/app.sh remove NAME                          remove one, its menu entries and the libraries only it needed
# TSO_ARM_APPS_DIR: where the lists are kept (default ~/.local/share/tso-arm/apps); TSO_ARM_APPS_MENU: where the menu
# entries go (default ~/.local/share/applications); TSO_ARM_APP_SANDBOX=1 or 0: Chromium's and Electron's sandbox
# used or not, whatever the user namespaces here allow (see cmd_run)
set -e
R=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
T=$R/bin/tso-arm
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
D=${TSO_ARM_APPS_DIR:-$DATA/tso-arm/apps}
LIB=$D/.libraries
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/tso-arm/apps
UBUNTU=${TSO_ARM_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
say() { echo "tso-arm app: $*" >&2; }
die() {
    say "$*"
    exit 1
}
if command -v curl >/dev/null; then
    get() { curl -fsSL --retry 2 -o "$2" "$1"; }
elif command -v wget >/dev/null; then
    get() { wget -q -O "$2" "$1"; }
else
    get() { die "needs curl or wget"; }
fi
# (undeb sets off, total, h, name and size: the functions here keep clear of those names)
. "$R/tools/undeb.sh"

# The root file system FEX uses: FEX_ROOTFS, or "RootFS" in FEX's configuration (a path, or a name under FEX's data
# directory, as tso-arm rootfs writes it)
rootfs_dir() {
    rr=${FEX_ROOTFS:-}
    if [ -z "$rr" ]; then
        if [ -n "${FEX_APP_CONFIG_LOCATION:-}" ]; then
            rc=${FEX_APP_CONFIG_LOCATION%/}
        elif [ -d "$HOME/.fex-emu" ]; then
            rc=$HOME/.fex-emu
        else
            rc=${XDG_CONFIG_HOME:-$HOME/.config}/fex-emu
        fi
        rr=$(sed -n 's/.*"RootFS"[^"]*"\([^"]*\)".*/\1/p' "$rc/Config.json" 2>/dev/null | head -n 1)
    fi
    [ -n "$rr" ] || die "no root file system: 'tso-arm rootfs' fetches one"
    case $rr in
    /*) ;;
    *) rr=$DATA/fex-emu/RootFS/$rr ;;
    esac
    [ -d "$rr/usr" ] || die "the root file system $rr is not there: 'tso-arm rootfs' fetches one"
    echo "${rr%/}"
}

# A field of a Debian package's control file: control PACKAGE.deb FIELD
control() {
    if command -v dpkg-deb >/dev/null; then
        dpkg-deb -f "$1" "$2"
        return
    fi
    co=8
    ct=$(wc -c <"$1")
    while [ $co -lt $ct ]; do
        ch=$(tail -c +$((co + 1)) "$1" | head -c 60)
        cn=$(printf '%s' "$ch" | cut -c1-16 | tr -d ' /')
        cs=$(printf '%s' "$ch" | cut -c49-58 | tr -d ' ')
        case $cn in
        control.tar.xz) cd_="xz -dc" ;;
        control.tar.zst) cd_="zstd -dcq" ;;
        control.tar.gz) cd_="gzip -dc" ;;
        *) cd_= ;;
        esac
        if [ -n "$cd_" ]; then
            tail -c +$((co + 61)) "$1" | head -c $cs | $cd_ | tar -xOf - ./control 2>/dev/null |
                awk -v f="$2" '$0 ~ "^" f ":" { sub("^[^:]*: *", ""); v = $0; on = 1; next }
                    on && /^[ \t]/ { v = v " " $0; next } { on = 0 } END { print v }'
            return
        fi
        co=$((co + 60 + cs + cs % 2))
    done
}

# Ubuntu 24.04's packages (noble, its updates and its security fixes; main and universe), the newest of each first:
# "NAME FILENAME SHA256 DEPENDS" lines and "provides NAME PACKAGE" lines, kept for a day. Each Packages.xz is checked
# against InRelease, whose signature gpgv checks with the root file system's Ubuntu keyring where gpgv is there.
ubuntu_index() { # ROOTFS
    ui=$CACHE/ubuntu-noble.idx
    if [ -f "$ui" ] && [ -n "$(find "$ui" -mmin -1440 2>/dev/null)" ]; then
        echo "$ui"
        return
    fi
    mkdir -p "$CACHE"
    ut=$(mktemp -d "$CACHE/.tmp.XXXXXX")
    key=$1/usr/share/keyrings/ubuntu-archive-keyring.gpg
    : >"$ut/all"
    for dist in noble-security noble-updates noble; do
        say "reading Ubuntu's index ($dist)"
        get "$UBUNTU/dists/$dist/InRelease" "$ut/InRelease" || die "no connection to $UBUNTU"
        if command -v gpgv >/dev/null && [ -f "$key" ]; then
            gpgv --keyring "$key" "$ut/InRelease" >/dev/null 2>&1 || die "Ubuntu's InRelease for $dist has no valid signature"
        else
            say "(no gpgv or Ubuntu keyring: the index is checked against InRelease, InRelease's signature is not)"
        fi
        for comp in main universe; do
            up=$comp/binary-amd64/Packages.xz
            get "$UBUNTU/dists/$dist/$up" "$ut/p.xz" || die "could not fetch $UBUNTU/dists/$dist/$up"
            us=$(awk -v p="$up" '/^SHA256:/ { s = 1; next } /^[A-Za-z]/ { s = 0 } s && $3 == p { print $1 }' "$ut/InRelease")
            [ -n "$us" ] && [ "$(sha256sum "$ut/p.xz" | cut -d' ' -f1)" = "$us" ] || die "$dist/$up does not match its InRelease"
            xz -dc "$ut/p.xz" >>"$ut/all"
            echo >>"$ut/all"
        done
    done
    awk '
    function flush(   n, a, i, x) { if (pkg != "" && !(pkg in seen)) { seen[pkg] = 1; print pkg, file, sum, dep
        n = split(prov, a, ","); for (i = 1; i <= n; i++) { x = a[i]; sub(/\(.*/, "", x); gsub(/[ \t]/, "", x); if (x != "") print "provides", x, pkg } }
        pkg = ""; file = ""; sum = ""; dep = ""; prov = "" }
    /^Package: / { flush(); pkg = $2; next }
    /^Filename: / { file = $2; next }
    /^SHA256: / { sum = $2; next }
    /^(Pre-)?Depends: / { sub(/^[^:]*: */, ""); d = $0; gsub(/[ \t]/, "", d); dep = (dep == "" ? d : dep "," d); next }
    /^Provides: / { sub(/^Provides: */, ""); prov = $0; next }
    /^$/ { flush() }
    END { flush() }' "$ut/all" >"$ui.new"
    rm -rf "$ut"
    mv "$ui.new" "$ui"
    echo "$ui"
}

# What the root file system came with: its packages and what they provide (not what tso-arm app added: a program's
# libraries are worked out against this, so that each program lists all it needs of them)
have_list() { # ROOTFS
    awk '/^Package: / { p = $2 } /^Status: .* installed/ { ok[p] = 1 } /^Provides: / { pv[p] = $0 }
    END { for (p in ok) { print p; if (p in pv) { s = pv[p]; sub(/^Provides: */, "", s); n = split(s, a, ",")
        for (i = 1; i <= n; i++) { x = a[i]; sub(/\(.*/, "", x); gsub(/[ \t]/, "", x); print x } } } }' "$1/var/lib/dpkg/status" |
        sed 's/:.*//' | sort -u
}

# The library packages a list of dependencies needs that the root file system lacks, and theirs in turn: "fetch
# PACKAGE" lines; "missing PACKAGE" for what Ubuntu has not or what is no library (tools and scripts are not fetched)
needed() { # INDEX HAVE DEPENDS
    awk -v deps="$3" '
    FILENAME == ARGV[1] { if ($1 == "provides") { if (!($2 in prov)) prov[$2] = $3 } else info[$1] = $4; next }
    { have[$1] = 1 }
    function want(list,   groups, n, i, alts, m, j, x, pick) {
        n = split(list, groups, ",")
        for (i = 1; i <= n; i++) {
            if (groups[i] == "") continue
            m = split(groups[i], alts, "|"); pick = ""
            for (j = 1; j <= m; j++) { x = alts[j]; sub(/\(.*/, "", x); sub(/:.*/, "", x); alts[j] = x; if (x in have || x in got) pick = "-" }
            if (pick == "-") continue
            for (j = 1; j <= m && pick == ""; j++) { x = alts[j]; if (x in info) pick = x; else if (x in prov) pick = prov[x] }
            if (pick == "") { if (!(alts[1] in missing)) { missing[alts[1]] = 1; print "missing", alts[1] } continue }
            if (pick in have || pick in got) continue
            if (pick !~ /^lib/) { if (!(pick in missing)) { missing[pick] = 1; print "missing", pick } continue }
            got[pick] = 1; print "fetch", pick
            want(info[pick])
        }
    }
    END { want(deps) }' "$1" "$2"
}

# Unpacks a package's data into the root file system, its new files only (what is there stays), and lists them in
# LIST, and the directories it makes in LIST.dirs (directories the root file system had stay, empty ones as well)
add_to_rootfs() { # PACKAGE.deb ROOTFS LIST
    at=$(mktemp -d "$D/.tmp.XXXXXX")
    undeb "$1" "$at"
    (cd "$at" && find . ! -type d) | sed 's,^\./,/,' | while read -r af; do
        if [ ! -e "$2$af" ] && [ ! -L "$2$af" ]; then
            ad=$(dirname "$af")
            while [ ! -d "$2$ad" ]; do
                echo "$ad" >>"$3.dirs"
                echo "$ad" >>"$D/.dirs"
                ad=$(dirname "$ad")
            done
            mkdir -p "$(dirname "$2$af")"
            mv "$at$af" "$2$af"
            echo "$af" >>"$3"
        fi
    done
    rm -rf "$at"
}

# Removes what LIST names from the root file system: its files, then the directories it made, when empty
remove_listed() { # LIST ROOTFS
    while read -r rf; do rm -f "$2$rf"; done <"$1"
    if [ -f "$1.dirs" ]; then
        sort -u -r "$1.dirs" | while read -r rd; do rmdir "$2$rd" 2>/dev/null || true; done
    fi
}

fetch_ubuntu() { # PACKAGE INDEX ROOTFS LIST
    set -- "$1" "$2" "$3" "$4" $(awk -v p="$1" '$1 == p { print $2, $3; exit }' "$2")
    [ $# = 6 ] || die "$1 is not in Ubuntu's index"
    ft=$(mktemp -d "$D/.tmp.XXXXXX")
    get "$UBUNTU/$5" "$ft/p.deb" || die "could not fetch $UBUNTU/$5"
    [ "$(sha256sum "$ft/p.deb" | cut -d' ' -f1)" = "$6" ] || die "$5 does not match Ubuntu's index"
    add_to_rootfs "$ft/p.deb" "$3" "$4"
    rm -rf "$ft"
}

# A path inside the root file system with its symbolic links followed there (absolute ones lead into it again)
resolve() { # ROOTFS PATH
    rp=$2
    ri=0
    while [ -L "$1$rp" ] && [ $ri -lt 16 ]; do
        rl=$(readlink "$1$rp")
        case $rl in
        /*) rp=$rl ;;
        *) rp=$(dirname "$rp")/$rl ;;
        esac
        ri=$((ri + 1))
    done
    echo "$rp"
}

# The programs 'install' knows by name, from their makers' own addresses: a package ("url"), or the package of that
# name in the maker's package index ("index BASE DIST/COMPONENT PACKAGE", checked against the index's SHA256)
catalog() {
    case $1 in
    discord) echo "url https://discord.com/api/download?platform=linux&format=deb" ;;
    zoom) echo "url https://zoom.us/client/latest/zoom_amd64.deb" ;;
    spotify) echo "index https://repository.spotify.com stable/non-free spotify-client" ;;
    slack) echo "index https://packagecloud.io/slacktechnologies/slack/debian jessie/main slack-desktop" ;;
    signal) echo "index https://updates.signal.org/desktop/apt xenial/main signal-desktop" ;;
    edge | microsoft-edge) echo "index https://packages.microsoft.com/repos/edge stable/main microsoft-edge-stable" ;;
    chrome | google-chrome) echo "index https://dl.google.com/linux/chrome/deb stable/main google-chrome-stable" ;;
    *) return 1 ;;
    esac
}

# Fetches a catalog entry's package to FILE
fetch_catalog() { # NAME FILE
    set -- "$1" "$2" $(catalog "$1")
    case $3 in
    url)
        say "fetching $1 from $4"
        get "$4" "$2" || die "could not fetch $4"
        ;;
    index)
        ix=$(mktemp "$D/.tmp.XXXXXX")
        if ! get "$4/dists/$5/binary-amd64/Packages" "$ix" 2>/dev/null; then
            get "$4/dists/$5/binary-amd64/Packages.gz" "$ix.gz" || die "could not read $4's package index"
            gzip -dc "$ix.gz" >"$ix"
            rm -f "$ix.gz"
        fi
        set -- "$@" $(pick "$ix" "$6")
        rm -f "$ix"
        [ $# = 9 ] || die "$4's index has no $6"
        say "fetching $6 $7 from $4"
        get "$4/$8" "$2" || die "could not fetch $4/$8"
        [ "$(sha256sum "$2" | cut -d' ' -f1)" = "$9" ] || die "$8 does not match $4's index"
        ;;
    esac
}

# The libraries a list of dependencies needs that the root file system came without, each fetched unless another
# program's are there, listed for the program ($app, $rfs, $work of cmd_install)
fetch_libraries() { # DEPENDS
    idx=$(ubuntu_index "$rfs")
    [ -f "$work/have" ] || have_list "$rfs" >"$work/have"
    needed "$idx" "$work/have" "$1" >"$work/need"
    for lp in $(awk '$1 == "fetch" { print $2 }' "$work/need"); do
        grep -qx "$lp" "$D/$app/libraries" || echo "$lp" >>"$D/$app/libraries"
        [ -f "$LIB/$lp" ] && continue
        say "library $lp from Ubuntu 24.04"
        : >"$LIB/$lp.new"
        fetch_ubuntu "$lp" "$idx" "$rfs" "$LIB/$lp.new"
        mv "$LIB/$lp.new" "$LIB/$lp"
        [ -f "$LIB/$lp.new.dirs" ] && mv "$LIB/$lp.new.dirs" "$LIB/$lp.dirs"
    done
    miss=$(awk '$1 == "missing" { printf "%s ", $2 }' "$work/need")
    [ -n "$miss" ] && say "not in the root file system, not fetched (no libraries): $miss"
    return 0
}

cmd_install() {
    [ $# -ge 1 ] || die "usage: tso-arm app install NAME | PACKAGE.deb | https://URL (names: chrome, discord, edge, signal, slack, spotify, zoom)"
    rfs=$(rootfs_dir)
    [ -w "$rfs/usr" ] || die "the root file system $rfs is not writable for you (installed for every user?): 'tso-arm rootfs' fetches one of your own"
    mkdir -p "$D"
    work=$(mktemp -d "$D/.tmp.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    case $1 in
    https://*)
        say "fetching $1"
        get "$1" "$work/app.deb" || die "could not fetch $1"
        deb=$work/app.deb
        ;;
    http://*) die "only https addresses: $1" ;;
    *)
        if [ ! -e "$1" ] && catalog "$1" >/dev/null; then
            fetch_catalog "$1" "$work/app.deb"
            deb=$work/app.deb
        else
            deb=$1
        fi
        ;;
    esac
    [ -f "$deb" ] || die "$deb: no such file"
    package=$(control "$deb" Package)
    ver=$(control "$deb" Version)
    arch=$(control "$deb" Architecture)
    [ -n "$package" ] || die "$1 is not a Debian package"
    # known by the name it was asked for (spotify: the package spotify-client), else by its package's
    if catalog "$1" >/dev/null 2>&1 && [ ! -e "$1" ]; then
        app=$1
    else
        app=$package
    fi
    case $arch in
    amd64 | i386 | all) ;;
    *) die "$app is a package for $arch, not for x86 ($arch programs run without tso-arm)" ;;
    esac
    if [ -f "$D/$app/files" ]; then
        say "$app is installed already: replacing it"
        cmd_remove "$app" >/dev/null 2>&1
    fi
    mkdir -p "$D/$app" "$LIB"
    : >"$D/$app/files"
    : >"$D/$app/libraries"
    say "$package $ver: into $rfs"
    add_to_rootfs "$deb" "$rfs" "$D/$app/files"
    echo "$package $ver" >"$D/$app/version"

    deps=$(control "$deb" Depends | tr -d ' \t')
    pre=$(control "$deb" Pre-Depends | tr -d ' \t')
    [ -n "$pre" ] && deps="$deps,$pre"
    [ -n "$deps" ] && fetch_libraries "$deps"

    # the program the package's menu entry starts, and an entry for this user that starts it through tso-arm
    apps=${TSO_ARM_APPS_MENU:-$DATA/applications}
    mkdir -p "$apps"
    tsoarm=$(command -v tso-arm 2>/dev/null || echo "$T")
    : >"$D/$app/desktop"
    # (menu entries elsewhere in the package as well: Spotify's and Edge's install scripts copy theirs into place)
    for df in $(grep '^/usr/share/applications/.*\.desktop$' "$D/$app/files") $(grep '\.desktop$' "$D/$app/files" | grep -v '^/usr/share/applications/'); do
        [ -s "$D/$app/exec" ] && [ "${df#/usr/share/applications/}" = "$df" ] && break
        ex=$(sed -n 's/^Exec=//p' "$rfs$df" | head -n 1)
        [ -n "$ex" ] || continue
        cmd=${ex%% *}
        case $cmd in
        /*) ;;
        *) cmd=/usr/bin/$cmd ;;
        esac
        prog=$(resolve "$rfs" "$cmd")
        [ -e "$rfs$prog" ] || continue
        [ -s "$D/$app/exec" ] || echo "$prog" >"$D/$app/exec"
        out=$apps/tso-arm-$app-$(basename "$df")
        icon=$(sed -n 's/^Icon=//p' "$rfs$df" | head -n 1)
        case $icon in
        /*) icon=$rfs$icon ;;
        ?*)
            ic=$(ls -S "$rfs"/usr/share/icons/hicolor/*/apps/"$icon".png "$rfs"/usr/share/pixmaps/"$icon".png \
                "$rfs"/usr/share/pixmaps/"$icon".svg "$rfs"/usr/share/icons/hicolor/scalable/apps/"$icon".svg 2>/dev/null | head -n 1)
            [ -n "$ic" ] && icon=$ic
            ;;
        esac
        args=${ex#"${ex%% *}"}
        sed -e "s|^Exec=.*|Exec=$tsoarm app run $app$args|" -e '/^TryExec=/d' -e "s|^Icon=.*|Icon=$icon|" "$rfs$df" >"$out"
        echo "$out" >>"$D/$app/desktop"
    done
    if [ ! -s "$D/$app/exec" ]; then
        # no menu entry: the package's command of its own name
        for c in /usr/bin/$app /usr/bin/$package /opt/$app/$app; do
            if [ -e "$rfs$c" ]; then
                resolve "$rfs" "$c" >"$D/$app/exec"
                break
            fi
        done
    fi
    # libraries its programs need that its package does not name (Spotify's and Zoom's libatomic): what the root file
    # system's dynamic loader does not find for them, from the Ubuntu package Debian names after the library
    # (libfoo.so.1 in libfoo1, libfoo2.so.3 in libfoo2-3) or its 64-bit-time_t name of Ubuntu 24.04 (libfoo1t64).
    # The loader (--list, as ldd runs it; nothing of the program runs) names what it misses, or the first one it misses
    # with "error while loading shared libraries", with the package's own library directories on its path (Zoom
    # brings its Qt): again after each round, at most eight
    if [ -s "$D/$app/exec" ]; then
        pdir=$(dirname "$(cat "$D/$app/exec")")
        own=$(grep '\.so[.0-9]*$' "$D/$app/files" | xargs -r -n1 dirname | sort -u | tr '\n' ':')
        # (the loader through the root file system's own links: /lib64/ld-linux-x86-64.so.2 names /lib/x86_64-linux-gnu/...)
        loader=$rfs$(resolve "$rfs" /lib64/ld-linux-x86-64.so.2)
        : >"$work/tried"
        round=0
        while [ $round -lt 8 ]; do
            round=$((round + 1))
            # (its programs, and native Node modules: Slack's keyboard module loads libxkbfile, which the root file
            # system lacks and Slack's package does not name; without it Slack's window stayed black)
            for b in $(cat "$D/$app/exec") $(grep "^$pdir/[^/]*\$" "$D/$app/files" | grep -v '\.so') $(grep '\.node$' "$D/$app/files"); do
                [ -f "$rfs$b" ] && [ "$(head -c 4 "$rfs$b" | tail -c 3)" = ELF ] || continue
                "$T" run "$loader" --library-path "${own%:}" --list "$rfs$b" 2>&1 </dev/null | awk '/=> not found/ { print $1 }
                    /error while loading shared libraries: / { s = $0; sub(/.*error while loading shared libraries: /, "", s); sub(/:.*/, "", s); print s }'
            done | sort -u | grep -vxF -f "$work/tried" >"$work/sonames" || true
            [ -s "$work/sonames" ] || break
            cat "$work/sonames" >>"$work/tried"
            idx=$(ubuntu_index "$rfs")
            more=$(awk 'FILENAME == ARGV[1] { if ($1 != "provides") info[$1] = 1; next }
                { so = $1; base = so; sub(/\.so.*/, "", base); v = so; if (!sub(/.*\.so\./, "", v)) next; sub(/\..*/, "", v)
                  base = tolower(base); gsub(/_/, "-", base); c = (base ~ /[0-9]$/) ? base "-" v : base v
                  if (c in info) print c; else if ((c "t64") in info) print c "t64"; else print "unknown " so }' "$idx" "$work/sonames")
            unknown=$(echo "$more" | awk '$1 == "unknown" { printf "%s ", $2 }')
            [ -n "$unknown" ] && say "libraries its programs need that no Ubuntu package is named after: $unknown"
            # fetched even where the root file system's package list names the package: FEX's root file system is
            # trimmed (its list has libatomic1, the library is not there)
            for lp in $(echo "$more" | awk '$1 != "unknown"'); do
                grep -qx "$lp" "$D/$app/libraries" || echo "$lp" >>"$D/$app/libraries"
                if [ ! -f "$LIB/$lp" ]; then
                    say "library $lp from Ubuntu 24.04"
                    : >"$LIB/$lp.new"
                    fetch_ubuntu "$lp" "$idx" "$rfs" "$LIB/$lp.new"
                    mv "$LIB/$lp.new" "$LIB/$lp"
                    [ -f "$LIB/$lp.new.dirs" ] && mv "$LIB/$lp.new.dirs" "$LIB/$lp.dirs"
                fi
                ld=$(awk -v p="$lp" '$1 == p { print $4; exit }' "$idx")
                [ -n "$ld" ] && fetch_libraries "$ld"
            done
        done
    fi
    # a Chromium or Electron program (its files, or Discord's, whose package holds only the starter of the Electron
    # program it fetches): started in its sandbox where user namespaces allow it, else with --no-sandbox (cmd_run)
    if [ "$app" = discord ] || grep -q '/chrome-sandbox$\|/v8_context_snapshot\.bin$\|/snapshot_blob\.bin$\|/libcef\.so$' "$D/$app/files"; then
        : >"$D/$app/chromium"
    fi
    if command -v update-desktop-database >/dev/null; then
        update-desktop-database "$apps" 2>/dev/null || true
    fi
    if [ -s "$D/$app/exec" ]; then
        say "installed $app $ver ($(wc -l <"$D/$app/files") files, $(wc -l <"$D/$app/libraries") libraries from Ubuntu): 'tso-arm app run $app' or its menu entry starts it"
    else
        say "installed $app $ver; its package names no program to start: 'tso-arm run $rfs/PATH' starts one of its programs"
    fi
}

cmd_list() {
    for ad in "$D"/*/; do
        [ -f "$ad/files" ] || continue
        echo "$(basename "$ad") $(cat "$ad/version" 2>/dev/null)  $(cat "$ad/exec" 2>/dev/null)"
    done
}

# Starts the program. A Chromium or Electron program (Chromium's snapshot or its sandbox helper next to it) runs in
# its own sandbox where user namespaces are allowed (its renderers in user, PID and network namespaces of their own,
# without the files, under seccomp-bpf filters, which FEX emulates); unpacked, its setuid sandbox helper has no root
# rights, so elsewhere it runs with --no-sandbox, its renderers without that protection (sandbox_usable below).
cmd_run() {
    [ $# -ge 1 ] || die "usage: tso-arm app run NAME [ARGS...]"
    app=$1
    shift
    [ -s "$D/$app/exec" ] || die "$app is not installed with a program to start ('tso-arm app list')"
    rfs=$(rootfs_dir)
    prog=$rfs$(cat "$D/$app/exec")
    # Discord's package holds only a starter, which fetches the Electron program into ~/.config/discord on its first
    # start and starts it without the options it was given (its GPU process then tried the sandbox and did not start:
    # "GPU process isn't usable"): once it is there, that program itself
    if [ "$app" = discord ] && [ -x "${XDG_CONFIG_HOME:-$HOME/.config}/discord/Discord" ]; then
        prog=${XDG_CONFIG_HOME:-$HOME/.config}/discord/Discord
    fi
    if [ -e "$D/$app/chromium" ] && ! sandbox_usable; then
        set -- --no-sandbox "$@"
    fi
    exec "$T" run "$prog" "$@"
}

# Whether a Chromium or Electron program can use its namespace sandbox here: user namespaces for an unprivileged
# process (not turned off; where AppArmor restricts them, allowed to tso-arm's FEX by 'tso-arm userns allow').
# TSO_ARM_APP_SANDBOX=1 or 0 decides instead.
sandbox_usable() {
    case ${TSO_ARM_APP_SANDBOX:-} in
    1) return 0 ;;
    0) return 1 ;;
    esac
    [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" != 0 ] || return 1
    [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 1)" != 0 ] || return 1
    if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
        [ -f /etc/apparmor.d/tso-arm-fex ] || return 1
    fi
    return 0
}

cmd_remove() {
    [ $# -ge 1 ] || die "usage: tso-arm app remove NAME"
    app=$1
    [ -f "$D/$app/files" ] || die "$app is not installed ('tso-arm app list')"
    rfs=$(rootfs_dir)
    rn=$(wc -l <"$D/$app/files")
    remove_listed "$D/$app/files" "$rfs"
    # the libraries fetched for it, unless another program is installed so: a program lists those it needed and the
    # root file system lacked, not those another one had fetched already (Zoom's libatomic after Spotify's), so all stay
    # until the last program goes
    others=$(ls -d "$D"/*/files 2>/dev/null | grep -vc "^$D/$app/files\$" || true)
    if [ "${others:-0}" = 0 ]; then
        for lf in "$LIB"/*; do
            [ -f "$lf" ] || continue
            case $lf in *.dirs) continue ;; esac
            remove_listed "$lf" "$rfs"
            rm -f "$lf" "$lf.dirs"
            say "removed library $(basename "$lf")"
        done
        # and every directory tso-arm app made that is empty now (one a program and a library shared)
        if [ -f "$D/.dirs" ]; then
            sort -u -r "$D/.dirs" | while read -r rd; do rmdir "$rfs$rd" 2>/dev/null || true; done
            rm -f "$D/.dirs"
        fi
    fi
    while read -r de; do rm -f "$de"; done <"$D/$app/desktop" 2>/dev/null || true
    # the menu's list of which entry opens which kind of file, without the removed ones
    apps=${TSO_ARM_APPS_MENU:-$DATA/applications}
    if [ -s "$D/$app/desktop" ] && [ -d "$apps" ] && command -v update-desktop-database >/dev/null; then
        update-desktop-database "$apps" 2>/dev/null || true
    fi
    rm -rf "${D:?}/$app"
    say "removed $app ($rn files)"
}

# where the programs go: the root file system
cmd_rootfs() {
    rootfs_dir
}

case ${1:-} in
install | list | run | remove | rootfs)
    sub=$1
    shift
    cmd_$sub "$@"
    ;;
*) die "usage: tso-arm app install NAME | PACKAGE.deb | https://URL; app list; app run NAME [ARGS...]; app remove NAME" ;;
esac

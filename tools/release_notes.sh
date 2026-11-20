#!/bin/sh
# The notes of one version from CHANGELOG.md, for its GitHub release: the lines of a paragraph or of a list item
# joined into one (GitHub shows every line break of a release text as one).
#   tools/release_notes.sh VERSION [CHANGELOG]
set -e
[ $# -ge 1 ] || { echo "usage: tools/release_notes.sh VERSION [CHANGELOG]" >&2; exit 1; }
awk -v v="$1" '
/^## / { on = ($2 == v); next }
!on { next }
NF == 0 { if (p != "") print p; print ""; p = ""; next }
/^- / { if (p != "") print p; p = $0; next }
{ sub(/^ +/, ""); p = (p == "") ? $0 : p " " $0 }
END { if (p != "") print p }
' "${2:-$(dirname "$0")/../CHANGELOG.md}"

#!/bin/sh
# check-dist.sh [VERSION] — does the Ultralisp dist serve this version of
# rulisp? docs/releasing.md step 8. Reads the dist's release index, fetches
# the rulisp archive it names and compares that archive's lisp/rulisp.asd
# :version with VERSION (default: the tree's). Exit 1 when they differ —
# the dist polls GitHub on its own schedule and can lag a tag by days.
set -e
cd "$(dirname "$0")/.."
WANT=${1:-$(sed -n 's/^version = "\([^"]*\)"/\1/p' crates/rulisp/Cargo.toml)}
DIST=http://dist.ultralisp.org/ultralisp.txt
INDEX=$(curl -sfL "$DIST" | awk -F': ' '/^release-index-url/ {print $2}' | tr -d '\r')
[ -n "$INDEX" ] || { echo "FAIL: no release-index-url at $DIST"; exit 1; }
LINE=$(curl -sfL "$INDEX" | grep '^onlyarche-rulisp ' || true)
[ -n "$LINE" ] || { echo "FAIL: onlyarche-rulisp is not in $INDEX"; exit 1; }
URL=$(echo "$LINE" | awk '{print $2}')
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -sfL "$URL" | tar -xz -C "$TMP"
GOT=$(sed -n 's/.*:version "\([^"]*\)".*/\1/p' "$TMP"/*/lisp/rulisp.asd | head -1)
if [ "$GOT" = "$WANT" ]; then
    echo "ultralisp serves rulisp $GOT ($(basename "$URL"))"
else
    echo "ultralisp serves rulisp $GOT ($(basename "$URL")), not $WANT"; exit 1
fi

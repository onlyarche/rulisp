#!/bin/sh
# fetch's BOUNDARY §7 gate: the crate-agnostic audit (tools/rulisp-audit.sh)
# plus one fetch-specific rule — no OpenSSL, the point of this example is
# rustls. Run by `make test-fetch`.
set -e
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
"$CARGO" build --quiet
SO=$(ls ../../target/debug/libfetch.so ../../target/debug/libfetch.dylib \
        ../../target/release/libfetch.so ../../target/release/libfetch.dylib 2>/dev/null | head -1)
[ -n "$SO" ] || { echo "FAIL: libfetch not built"; exit 1; }
sh ../../tools/rulisp-audit.sh "$SO" .
if "$CARGO" tree 2>/dev/null | grep -Eq '(^| )(openssl|native-tls)'; then
    echo "FAIL: OpenSSL in the dependency graph — the point is rustls"; exit 1
fi
echo "audit ok: no OpenSSL"

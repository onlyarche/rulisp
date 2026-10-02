#!/bin/sh
# httpd's BOUNDARY §7 gate: the crate-agnostic audit (tools/rulisp-audit.sh)
# plus two httpd-specific rules — tokio's "signal"/"process" features stay
# out of the build (a feature a transitive dependency could switch on), and
# no second TLS stack or C library (OpenSSL, native-tls, aws-lc) joins the
# tree. Run by `make test-httpd`.
set -e
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
"$CARGO" build --quiet
SO=$(ls ../../target/debug/libhttpd.so ../../target/debug/libhttpd.dylib ../../target/debug/httpd.dll \
        ../../target/release/libhttpd.so ../../target/release/libhttpd.dylib ../../target/release/httpd.dll 2>/dev/null | head -1)
[ -n "$SO" ] || { echo "FAIL: libhttpd not built"; exit 1; }
sh ../../tools/rulisp-audit.sh "$SO" .
if "$CARGO" tree -e features 2>/dev/null | grep -Eq 'tokio feature "(signal|process)"'; then
    echo "FAIL: tokio signal/process in the feature graph — BOUNDARY §7"; exit 1
fi
if "$CARGO" tree 2>/dev/null | grep -Eq '(^| )(openssl|native-tls|aws-lc)'; then
    echo "FAIL: a second TLS stack or C library in the dependency graph"; exit 1
fi
echo "audit ok: no tokio signal/process, no OpenSSL/native-tls/aws-lc"

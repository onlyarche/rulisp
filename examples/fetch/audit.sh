#!/bin/sh
# BOUNDARY.md §7 says "audit dependencies for sigaction". This makes that
# audit executable instead of a claim in a README: a dependency that
# installs a signal handler destabilises SBCL's signal-driven GC in ways
# that surface days later, so it must fail the build, not a code review.
set -e
cd "$(dirname "$0")"

CARGO=${CARGO:-cargo}
command -v "$CARGO" >/dev/null || CARGO="$HOME/.cargo/bin/cargo"

"$CARGO" build --quiet
SO=$(ls ../../target/debug/libfetch.so ../../target/release/libfetch.so 2>/dev/null | head -1)
[ -n "$SO" ] || { echo "FAIL: libfetch not built"; exit 1; }

# glibc imports carry a version suffix (`U sigaction@GLIBC_2.2.5`), so the
# name must not be anchored with $ — that made this gate inert.
if nm -D --undefined-only "$SO" | grep -Eq ' (sigaction|signal|bsd_signal|sigprocmask|pthread_sigmask)(@|$)'; then
    echo "FAIL: $SO references a signal-disposition symbol"; exit 1
fi
if "$CARGO" tree -e features 2>/dev/null | grep -Eq 'tokio feature "(signal|process)"'; then
    echo "FAIL: tokio signal/process feature enabled (pulls the SIGCHLD driver)"; exit 1
fi
if "$CARGO" tree 2>/dev/null | grep -Eq '(^| )(openssl|native-tls)'; then
    echo "FAIL: OpenSSL in the dependency graph — the point is rustls"; exit 1
fi
if grep -v '^[[:space:]]*//' src/*.rs | grep -q 'block_on'; then
    echo "FAIL: block_on in the glue — every wait must be capped and Lisp-side"; exit 1
fi
echo "audit ok: no signal handlers, no OpenSSL, no block_on"

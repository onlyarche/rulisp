#!/bin/sh
# rulisp-audit.sh ARTIFACT [CRATE_DIR]
#
# BOUNDARY.md §7 as an executable check, for any glue crate:
#   1. the built artifact imports no signal-disposition symbol — a
#      dependency that installs a signal handler destabilises SBCL's
#      signal-driven GC in ways that surface days later;
#   2. with CRATE_DIR: tokio's "signal"/"process" features are off (the
#      latter pulls the SIGCHLD driver), and no `block_on` in the glue
#      sources — every wait must be capped in Rust and looped in Lisp.
# Exit 1 on any finding. Self-test: tools/rulisp-audit-selftest.sh builds
# a fixture that deliberately imports signal() and checks this script
# rejects it — so the gate cannot quietly go inert again (an anchored
# regex once did exactly that: glibc imports read `sigaction@GLIBC_2.2.5`).
set -e
SYMS='sigaction|signal|bsd_signal|sigprocmask|pthread_sigmask'
# `(@|$)` and not `$` alone: versioned glibc imports. `_?` right after the
# start or the separating space: Mach-O's leading underscore — and ONLY a
# leading one. The earlier `(^|[ _])` also matched an inner underscore, so
# `_dispatch_semaphore_signal` (imported by every macOS artifact) read as
# `_signal` and failed every macOS release build.
PATTERN="(^| )_?($SYMS)(@|\$)"
# selftest hook: symbol lines on stdin, exit 0 iff one is a signal import
[ "$1" = "--match" ] && { grep -Eq "$PATTERN"; exit $?; }

ARTIFACT=$1
CRATE_DIR=$2
[ -n "$ARTIFACT" ] || { echo "usage: rulisp-audit.sh ARTIFACT [CRATE_DIR]"; exit 2; }
[ -f "$ARTIFACT" ] || { echo "FAIL: no such artifact: $ARTIFACT"; exit 1; }

case "$(uname -s)" in
  Linux)  UNDEF="nm -D --undefined-only" ;;
  Darwin) UNDEF="nm -u" ;;           # Mach-O: names carry a leading underscore
  *) echo "SKIP: signal-import check is not implemented for $(uname -s) (use dumpbin /imports)"; exit 0 ;;
esac
if $UNDEF "$ARTIFACT" | grep -Eq "$PATTERN"; then
    echo "FAIL: $ARTIFACT imports a signal-disposition symbol:"
    $UNDEF "$ARTIFACT" | grep -E "$PATTERN"
    exit 1
fi

if [ -n "$CRATE_DIR" ]; then
    CARGO=${CARGO:-cargo}
    command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
    if "$CARGO" tree --manifest-path "$CRATE_DIR/Cargo.toml" -e features 2>/dev/null \
         | grep -Eq 'tokio feature "(signal|process)"'; then
        echo "FAIL: $CRATE_DIR enables tokio signal/process (pulls the SIGCHLD driver)"; exit 1
    fi
    if ls "$CRATE_DIR"/src/*.rs >/dev/null 2>&1 \
         && grep -v '^[[:space:]]*//' "$CRATE_DIR"/src/*.rs | grep -q 'block_on'; then
        echo "FAIL: block_on in $CRATE_DIR/src — cap the wait in Rust, loop in Lisp"; exit 1
    fi
fi
echo "audit ok: $ARTIFACT"

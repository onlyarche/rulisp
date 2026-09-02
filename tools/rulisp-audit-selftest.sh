#!/bin/sh
# Proves tools/rulisp-audit.sh can still fail: builds a fixture cdylib that
# deliberately imports signal() and requires the audit to reject it, then
# requires it to accept the wordbag example. Run from the repository root.
set -e
CARGO=${CARGO:-cargo}
command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
case "$(uname -s)" in Linux|Darwin) ;; *) echo "SKIP: selftest needs nm"; exit 0 ;; esac

"$CARGO" build --quiet --manifest-path tools/audit-fixture/Cargo.toml --target-dir target/audit-fixture
FIX=$(ls target/audit-fixture/debug/libaudit_fixture.so target/audit-fixture/debug/libaudit_fixture.dylib 2>/dev/null | head -1)
[ -n "$FIX" ] || { echo "FAIL: fixture did not build"; exit 1; }

if sh tools/rulisp-audit.sh "$FIX" >/dev/null 2>&1; then
    echo "FAIL: the audit accepted a library that imports signal() — the gate is inert"; exit 1
fi
echo "selftest: audit rejects the signal-importing fixture"

"$CARGO" build --quiet -p wordbag
OK=$(ls target/debug/libwordbag.so target/debug/libwordbag.dylib 2>/dev/null | head -1)
sh tools/rulisp-audit.sh "$OK" examples/wordbag
echo "selftest ok"

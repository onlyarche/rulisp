#!/bin/sh
# Proves tools/rulisp-audit.sh can still fail: builds a fixture cdylib that
# deliberately imports signal() and requires the audit to reject it, then
# requires it to accept the wordbag example. Run from the repository root.
set -e
CARGO=${CARGO:-cargo}
command -v "$CARGO" >/dev/null 2>&1 || CARGO="$HOME/.cargo/bin/cargo"
case "$(uname -s)" in Linux|Darwin) ;; *) echo "SKIP: selftest needs nm"; exit 0 ;; esac

# The pattern itself, both ways, on the three symbol shapes nm prints: a
# versioned glibc import, a Mach-O name with its leading underscore, and a
# Mach-O name with an INNER `_signal` — the last one is not a signal import
# and once failed every macOS release build.
printf '                 U sigaction@GLIBC_2.2.5\n' | sh tools/rulisp-audit.sh --match \
    || { echo "FAIL: versioned glibc sigaction import not matched"; exit 1; }
printf '_signal\n' | sh tools/rulisp-audit.sh --match \
    || { echo "FAIL: Mach-O _signal not matched"; exit 1; }
if printf '_dispatch_semaphore_signal\n' | sh tools/rulisp-audit.sh --match; then
    echo "FAIL: false positive on _dispatch_semaphore_signal (inner underscore)"; exit 1
fi
echo "selftest: pattern matches signal imports and only those"

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

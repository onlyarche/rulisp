#!/bin/sh
# check-1.0.sh — docs/stability.md §8, the 1.0 exit criteria as commands.
# Only constants, names and counts on lines the documents already own;
# nothing parses prose. Run by `make check-1.0` and the MSRV CI job.
set -e
cd "$(dirname "$0")/.."
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# criterion 1: abi_version() still 1, on both sides of the boundary
if grep -q '^pub const ABI_VERSION: u32 = 1;' crates/rulisp-runtime/src/lib.rs \
   && grep -q '^(defconstant +abi-version+ 1)' lisp/src/ffi.lisp; then
    ok "criterion 1: ABI 1 in rulisp-runtime and the loader"
else bad "criterion 1: the ABI constant is not 1 on both sides"; fi

# criterion 3: the gates that make "no break" a CI fact exist by name — a
# tripwire against quiet removal (the pins move at each release)
for needle in 'cargo-semver-checks-action' 'make compat PREV=v[0-9]' 'gh release download v[0-9]' 'make dist-dryrun' 'make check-versions'; do
    if grep -qE -- "$needle" .github/workflows/ci.yml; then ok "criterion 3: ci.yml runs $needle"
    else bad "criterion 3: ci.yml lost $needle"; fi
done
if grep -q ':rulisp-v06' tests/run-m4.lisp; then ok "criterion 3: run-m4 runs :rulisp-v06"
else bad "criterion 3: tests/run-m4.lisp does not run :rulisp-v06"; fi
if grep -q '^compat:' Makefile && grep -q '^dist-dryrun:' Makefile; then ok "criterion 3: make compat / dist-dryrun exist"
else bad "criterion 3: a Makefile gate target is missing"; fi
# the Lisp surface: every export is a row of the golden, and vice versa
exports=$(grep -c '^   #:' lisp/src/package.lisp)
rows=$(grep -c '^ (' tests/golden/lisp-api.sexp)
if [ "$exports" -eq "$rows" ]; then ok "Lisp surface: $exports exports = $rows golden rows"
else bad "Lisp surface: $exports exports vs $rows golden rows"; fi

# criterion 4: no GAP row in BOUNDARY §12; the claims register has nothing unverified
if [ "$(grep -c '^|.*GAP' BOUNDARY.md)" -eq 0 ]; then ok "criterion 4: BOUNDARY §12 has no GAP row"
else bad "criterion 4: BOUNDARY §12 has a GAP row"; fi
if grep -q ', 0 unverified\.' docs/claims.md; then ok "criterion 4: docs/claims.md: 0 unverified"
else bad "criterion 4: docs/claims.md has unverified claims"; fi

# criterion 5: the Quicklisp prerequisites' mechanical part — the dist dry run
if grep -q 'Quicklisp dist dry run' .github/workflows/ci.yml; then ok "criterion 5: the dist dry run runs in CI"
else bad "criterion 5: no dist dry run step in ci.yml"; fi

[ $fail -eq 0 ] && echo "1.0 exit criteria: every mechanical check holds" || echo "1.0 exit criteria: something does not hold"
exit $fail

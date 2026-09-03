#!/bin/sh
# check-versions.sh — one version string, every site that repeats it
# (docs/releasing.md step 1). crates/rulisp/Cargo.toml is the source of
# truth; the other sites must agree exactly, the docs' dependency lines by
# major.minor, and the three crates must declare one rust-version.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^version = "\([^"]*\)"/\1/p' crates/rulisp/Cargo.toml)
RV=$(sed -n 's/^rust-version = "\([^"]*\)"/\1/p' crates/rulisp/Cargo.toml)
MM=${V%.*}
[ -n "$V" ] && [ -n "$RV" ] || { echo "FAIL: no version/rust-version in crates/rulisp/Cargo.toml"; exit 1; }
fail=0
need() { # need FILE REGEX WHAT
  if grep -Eq "$2" "$1"; then echo "ok   $1: $3"
  else echo "FAIL $1: expected $3"; fail=1; fi
}
need crates/rulisp-macros/Cargo.toml  "^version = \"$V\"$"       "version $V"
need crates/rulisp-runtime/Cargo.toml "^version = \"$V\"$"       "version $V"
need crates/rulisp-macros/Cargo.toml  "^rust-version = \"$RV\"$" "rust-version $RV"
need crates/rulisp-runtime/Cargo.toml "^rust-version = \"$RV\"$" "rust-version $RV"
need crates/rulisp/Cargo.toml "^rulisp-macros = .*version = \"$V\""  "rulisp-macros pin $V"
need crates/rulisp/Cargo.toml "^rulisp-runtime = .*version = \"$V\"" "rulisp-runtime pin $V"
need lisp/rulisp.asd   ":version \"$V\""   ":version \"$V\""
need README.md         "^$V\. "            "status line starting \"$V.\""
need docs/quickstart.md "^rulisp = \"$MM\"" "rulisp = \"$MM\""
need docs/usage.md      "^rulisp = \"$MM\"" "rulisp = \"$MM\""
[ $fail -eq 0 ] && echo "versions consistent: $V (rust-version $RV)"
exit $fail

#!/bin/sh
# old-suite-verdict.sh LOG SKIPFILE — the rule of docs/stability.md §1 for
# the previous release's suite run against this tree's loader: the suite
# must have run to its summary, and every test that failed must be named in
# SKIPFILE (a test that reaches rulisp:: internals, recorded with its
# reason). Anything else is a break and fails the gate, by name.
log=$1; skip=$2
grep -a -q 'Did [0-9]* checks' "$log" || { echo "COMPAT-FAIL: the previous release's suite printed no summary — it did not run to the end"; exit 1; }
failed=$(grep -a -o '^ [A-Z0-9.-]* in RULISP-[A-Z0-9-]* ' "$log" | awk '{print tolower($1)}' | sort -u)
bad=0
for t in $failed; do
    if grep -q "^$t[[:space:]]" "$skip"; then
        echo "not counted (reaches rulisp:: internals, tests/compat/skipped-internal.txt): $t"
    else
        echo "COMPAT-FAIL: $t failed in the previous release's suite and is not a recorded internal test — a break"
        bad=1
    fi
done
[ "$bad" -eq 0 ] && echo "OLD-SUITE-OK ($(grep -a -o 'Did [0-9]* checks' "$log" | tail -1))"
exit $bad

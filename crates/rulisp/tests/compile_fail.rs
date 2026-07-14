//! M3 gate (c): the five forbidden shapes each fail to COMPILE with an
//! actionable message (trybuild snapshots in tests/ui/*.stderr).

#[test]
fn ui() {
    let t = trybuild::TestCases::new();
    t.compile_fail("tests/ui/*.rs");
}

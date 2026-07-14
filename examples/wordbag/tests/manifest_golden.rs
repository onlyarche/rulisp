//! M3 gate (a): the macro-assembled manifest must be byte-identical to the
//! golden snapshot frozen in M2.

#[test]
fn manifest_matches_golden() {
    let golden = include_str!("../../../tests/golden/wordbag.manifest.sexp");
    let rendered = wordbag::__rulisp_manifest_str();
    assert!(
        rendered == golden,
        "macro manifest deviates from golden:\n--- rendered ---\n{rendered}\n--- golden ---\n{golden}"
    );
}

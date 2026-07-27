//! M3 gate (a): the macro-assembled manifest must be byte-identical to the
//! golden snapshot frozen in M2.

#[test]
fn manifest_matches_golden() {
    // :target is inherently host-dependent — the golden was frozen on
    // x86_64 Linux; substitute the build target, everything else is
    // compared byte for byte.
    let golden = include_str!("../../../tests/golden/wordbag.manifest.sexp")
        .replace("x86_64-unknown-linux-gnu", rulisp::runtime::TARGET);
    let rendered = wordbag::__rulisp_manifest_str();
    assert!(
        rendered == golden,
        "macro manifest deviates from golden:\n--- rendered ---\n{rendered}\n--- golden ---\n{golden}"
    );
}

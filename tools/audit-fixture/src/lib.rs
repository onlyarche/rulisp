//! A library that installs a signal handler — exactly what BOUNDARY §7
//! forbids in a glue crate's dependency graph. The audit self-test builds
//! it and requires tools/rulisp-audit.sh to fail on it.

extern "C" {
    fn signal(sig: i32, handler: usize) -> usize;
}

/// Referenced from an exported symbol so the import survives linking.
#[no_mangle]
pub extern "C" fn audit_fixture_install() -> usize {
    // SIG_IGN on SIGINT — never called by anyone; it only has to be imported
    unsafe { signal(2, 1) }
}

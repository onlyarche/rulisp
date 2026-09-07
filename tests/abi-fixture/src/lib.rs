//! An artifact from a future ABI: its only export answers 2 where the
//! loader requires 1. `v06.abi-mismatch-refused` loads it through
//! `rulisp:use-crate` and expects `abi-mismatch-error` with expected 1,
//! actual 2 — BOUNDARY §1's "checked first, before the manifest is read",
//! which until v0.6 no test simulated.

#[no_mangle]
pub extern "C" fn abifix_rulisp_abi_version() -> u32 {
    2
}

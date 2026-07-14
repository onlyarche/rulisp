//! User-facing crate for rulisp glue crates.
//!
//! M1 scope: the `Error` type and a re-export of the runtime. The proc-macros
//! (`#[rulisp::handle]`, `#[rulisp::export]`, `module!`) and the `Callback`
//! type arrive in M3; until then glue shims are hand-written against
//! `rulisp_runtime` (see `tests/m1-handwritten/`, the ABI oracle).

pub use rulisp_runtime as runtime;

/// Generic string error for glue code that doesn't define its own error type.
/// Crosses the boundary as last-error type `"Error"`.
#[derive(Debug)]
pub struct Error(String);

impl Error {
    pub fn msg(m: impl Into<String>) -> Self {
        Error(m.into())
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

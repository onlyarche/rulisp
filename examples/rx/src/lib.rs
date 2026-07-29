//! rx: Rust's linear-time `regex` engine for Common Lisp.
//!
//! The rulisp quickstart example (docs/quickstart.md): wraps a real
//! crates.io dependency in ~60 lines of plain Rust. Unlike cl-ppcre's
//! backtracking engine, `regex` guarantees linear-time matching — no ReDoS.

use rulisp::prelude::*;

#[rulisp::handle]
pub struct Regex {
    inner: regex::Regex,
}

#[rulisp::export]
impl Regex {
    /// (rx:make-regex "[0-9]+") — a bad pattern signals rulisp:rust-error
    /// carrying regex's excellent multi-line parse error message.
    #[rulisp(constructor)]
    pub fn new(pattern: &str) -> Result<Regex, regex::Error> {
        Ok(Regex {
            inner: regex::Regex::new(pattern)?,
        })
    }

    pub fn is_match(&self, text: &str) -> bool {
        self.inner.is_match(text)
    }

    pub fn count(&self, text: &str) -> u64 {
        self.inner.find_iter(text).count() as u64
    }

    pub fn replace_all(&self, text: &str, replacement: &str) -> String {
        self.inner.replace_all(text, replacement).into_owned()
    }

    /// First match as (:option :string): NIL when there is none — no more
    /// sentinel values (v0.2).
    pub fn first_match(&self, text: &str) -> Option<String> {
        self.inner.find(text).map(|m| m.as_str().to_owned())
    }

    /// Iterate matches into a Lisp closure; a condition signaled inside the
    /// closure aborts iteration and re-signals in the caller.
    pub fn for_each_match(&self, text: &str, f: Callback<(&str,), ()>) -> Result<u64, Error> {
        let mut n = 0;
        for m in self.inner.find_iter(text) {
            f.call((m.as_str(),))?;
            n += 1;
        }
        Ok(n)
    }
}

#[rulisp::export]
pub fn escape(text: &str) -> String {
    regex::escape(text)
}

rulisp::module! {
    name: "rx",
    handles: [Regex],
    fns: [
        Regex::new, Regex::is_match, Regex::count, Regex::replace_all,
        Regex::first_match, Regex::for_each_match,
        escape,
    ],
}

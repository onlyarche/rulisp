// Issue #1: an explicit lifetime in an export signature let the borrowing
// helpers' unconstrained 'a be chosen by user code — &'static str compiled
// under #![forbid(unsafe_code)] and stashed a Lisp-owned buffer past the
// call (safe-Rust UAF). Every position that can name a lifetime must be
// rejected at the annotation's span.

use std::sync::Mutex;
use rulisp::Callback;

#[rulisp::handle]
pub struct Bag {
    n: Mutex<i64>,
}

// the original repro: free fn, &'static str
#[rulisp::export]
pub fn stash(s: &'static str) {
    let _ = s;
}

// nested inside Option
#[rulisp::export]
pub fn stash_opt(s: Option<&'static str>) {
    let _ = s;
}

// byte and scalar slices
#[rulisp::export]
pub fn stash_bytes(b: &'static [u8]) {
    let _ = b;
}

#[rulisp::export]
pub fn stash_vec(xs: &'static [i64]) {
    let _ = xs;
}

// a handle reference — would let the reference outlive the handle
#[rulisp::export]
pub fn stash_handle(bag: &'static Bag) {
    let _ = bag;
}

// a lifetime smuggled through Callback's generic arguments
#[rulisp::export]
pub fn with_cb(cb: Callback<'static, (i64,), ()>) {
    let _ = cb;
}

#[rulisp::export]
impl Bag {
    // the receiver position
    pub fn touch<'a>(&'a self) -> i64 {
        *self.n.lock().unwrap()
    }
}

fn main() {}

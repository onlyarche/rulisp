// Callbacks are borrowed for the duration of the export call only:
// storing one is a compile error (!Send/!Sync + lifetime pinning).

use rulisp::Callback;
use std::sync::Mutex;

static STASH: Mutex<Option<Callback<'static, (&'static str,), ()>>> = Mutex::new(None);

#[rulisp::export]
pub fn keep(f: Callback<(&str,), ()>) {
    *STASH.lock().unwrap() = Some(f);
}

fn main() {}

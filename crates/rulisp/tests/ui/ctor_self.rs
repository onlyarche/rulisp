// A constructor's shim calls Type::method(args) with no receiver, so
// #[rulisp(constructor)] on a &self method must be rejected with an
// actionable message rather than dropping the receiver silently.

use std::sync::Mutex;

#[rulisp::handle]
pub struct Client {
    n: Mutex<i64>,
}

#[rulisp::handle]
pub struct Req {
    n: Mutex<i64>,
}

#[rulisp::export]
impl Client {
    #[rulisp(constructor)]
    pub fn start(&self) -> Req {
        Req { n: Mutex::new(0) }
    }
}

fn main() {}

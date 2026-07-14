// &mut self is not exportable: concurrent &self calls on one handle are
// allowed by the thread contract, so mutation must be interior.

use std::sync::Mutex;

#[rulisp::handle]
pub struct Thing {
    n: Mutex<i64>,
}

#[rulisp::export]
impl Thing {
    pub fn bump(&mut self) {}
}

fn main() {}

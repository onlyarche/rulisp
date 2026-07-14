// A handle type must be Send + Sync + 'static: finalizers drop on any
// thread and same-handle calls may overlap.

use std::rc::Rc;

#[rulisp::handle]
pub struct Bad {
    data: Rc<Vec<u8>>,
}

fn main() {}

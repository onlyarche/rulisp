// Option<Handle> is not a result type, on a method or on a constructor:
// "the next item or none" is a bool wait plus a constructor.

pub struct Item;

pub struct Source;

#[rulisp::export]
impl Source {
    #[rulisp(constructor)]
    pub fn new() -> Source {
        Source
    }

    #[rulisp(constructor, name = "next-item")]
    pub fn next(_s: &Source) -> Option<Item> {
        None
    }
}

fn main() {}

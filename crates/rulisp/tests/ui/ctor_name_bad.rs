// #[rulisp(constructor, name = "...")] must be validated: the name becomes a
// Lisp symbol in the generated package, and the attribute grammar must not
// silently accept typos (a misspelled key used to be ignored).

use std::sync::Mutex;

#[rulisp::handle]
pub struct Bag {
    n: Mutex<i64>,
}

// name must be a string literal
#[rulisp::export]
impl Bag {
    #[rulisp(constructor, name = 42)]
    pub fn a() -> Bag {
        Bag { n: Mutex::new(0) }
    }
}

// name must be a usable symbol name
#[rulisp::export]
impl Bag {
    #[rulisp(constructor, name = "has space")]
    pub fn b() -> Bag {
        Bag { n: Mutex::new(0) }
    }
}

// name is only meaningful on a constructor
#[rulisp::export]
impl Bag {
    #[rulisp(name = "bag-len")]
    pub fn c(&self) -> i64 {
        *self.n.lock().unwrap()
    }
}

// unknown keys are errors, not silently ignored
#[rulisp::export]
impl Bag {
    #[rulisp(constuctor)]
    pub fn d() -> Bag {
        Bag { n: Mutex::new(0) }
    }
}

fn main() {}

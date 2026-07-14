// The module! registry is explicit: a typo in fns is an unresolved-const
// compile error, never a silently missing export.

#[rulisp::export]
pub fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

rulisp::module! {
    name: "rulisp-tests",
    handles: [],
    fns: [greeet],
}

fn main() {}

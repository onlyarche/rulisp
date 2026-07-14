// Types outside the closed v1 vocabulary are rejected at the macro.

#[rulisp::export]
pub fn nope(v: Vec<u8>) -> u64 {
    v.len() as u64
}

fn main() {}

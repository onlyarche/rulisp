// BOUNDARY §10: the on_dump hook is a fn with no parameters. Naming one
// that takes the server (the first thing a server author writes) must say
// so in rulisp's words, not only as a bare type mismatch.

#[rulisp::export]
pub fn ping() -> u32 {
    1
}

#[rulisp::export]
pub fn shutdown_server(_grace_ms: u64) {}

rulisp::module! {
    name: "rulisp-tests",
    handles: [],
    fns: [ping, shutdown_server],
    on_dump: shutdown_server,
}

fn main() {}

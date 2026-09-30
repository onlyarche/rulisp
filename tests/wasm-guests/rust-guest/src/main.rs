//! What an ordinary Rust program does to its host, for the WASI sandbox's
//! suite (tests/suite/wasm.lisp): std only, no WASI-specific code.
//! argv[1] picks the behaviour.
use std::io::{Read, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str).unwrap_or("hello") {
        // arguments, environment, stdin, a file, an escape, a write, a
        // directory listing, stderr, and an exit code
        "hello" => {
            println!("hello from rust, args={:?}", &args[1..]);
            println!("HOME={:?}", std::env::var("HOME").ok());
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).unwrap();
            println!("stdin={input:?}");
            match std::fs::read_to_string("/secret.txt") {
                Ok(s) => println!("file={s:?}"),
                Err(e) => println!("file error: {e}"),
            }
            match std::fs::read_to_string("/../outside.txt") {
                Ok(s) => println!("ESCAPED: {s:?}"),
                Err(e) => println!("escape refused: {e}"),
            }
            match std::fs::write("/new.txt", b"x") {
                Ok(()) => println!("WROTE a file"),
                Err(e) => println!("write refused: {e}"),
            }
            let entries = std::fs::read_dir("/").map(|d| d.count()).unwrap_or(0);
            println!("dir has {entries} entries");
            eprintln!("to stderr");
            std::process::exit(3);
        }
        // std's sleep asserts that the host's poll_oneoff succeeded
        "sleep" => {
            println!("before sleep");
            std::io::stdout().flush().unwrap();
            std::thread::sleep(std::time::Duration::from_secs(2));
            println!("after sleep");
        }
        // allocate until the allocator gives up
        "alloc" => {
            let mut hoard: Vec<Vec<u8>> = Vec::new();
            loop {
                hoard.push(vec![1u8; 1 << 20]);
            }
        }
        _ => {}
    }
}

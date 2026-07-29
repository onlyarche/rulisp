# Quickstart: wrapping a real crate in 10 minutes

We'll wrap [`regex`](https://crates.io/crates/regex) — Rust's linear-time
regular expression engine (no ReDoS, unlike backtracking engines) — and use
it from the REPL. The finished example lives in `examples/rx/`; every
snippet below is taken from a real session.

## Prerequisites

A Rust toolchain, SBCL (or CCL) with Quicklisp, and this repository set up
so ASDF finds the `rulisp` system — full per-platform instructions
(Linux/macOS, dependencies, troubleshooting) are in
[installation.md](installation.md).

## 1. The glue crate

```
cargo new --lib rx
```

`Cargo.toml`:

```toml
[package]
name = "rx"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
rulisp = "0.1"
regex = "1"
```

`src/lib.rs` — plain Rust, three macros, no `extern "C"` anywhere:

```rust
use rulisp::prelude::*;

#[rulisp::handle]
pub struct Regex {
    inner: regex::Regex,
}

#[rulisp::export]
impl Regex {
    #[rulisp(constructor)]
    pub fn new(pattern: &str) -> Result<Regex, regex::Error> {
        Ok(Regex { inner: regex::Regex::new(pattern)? })
    }

    pub fn is_match(&self, text: &str) -> bool {
        self.inner.is_match(text)
    }

    pub fn count(&self, text: &str) -> u64 {
        self.inner.find_iter(text).count() as u64
    }

    pub fn replace_all(&self, text: &str, replacement: &str) -> String {
        self.inner.replace_all(text, replacement).into_owned()
    }

    pub fn for_each_match(&self, text: &str, f: Callback<(&str,), ()>) -> Result<u64, Error> {
        let mut n = 0;
        for m in self.inner.find_iter(text) {
            f.call((m.as_str(),))?;
            n += 1;
        }
        Ok(n)
    }
}

#[rulisp::export]
pub fn escape(text: &str) -> String {
    regex::escape(text)
}

rulisp::module! {
    name: "rx",
    handles: [Regex],
    fns: [
        Regex::new, Regex::is_match, Regex::count, Regex::replace_all,
        Regex::for_each_match,
        escape,
    ],
}
```

Naming is mechanical: `Regex::new` (a constructor) becomes `rx:make-regex`,
methods become `rx:regex-is-match` etc., free fns keep their kebab-cased
name. What the macros add for you: panic catching in every shim, UTF-8
`(ptr,len)` string passing, opaque-handle lifecycle with GC finalizers,
error → condition mapping, and the embedded manifest the Lisp side reads.

## 2. Load and use it

```lisp
CL-USER> (asdf:load-system :rulisp)
CL-USER> (rulisp:use-crate #p"~/src/rx/")   ; cargo build + dlopen + codegen
#<CRATE "rx" gen 1 abi 1 :: 6 fns, 1 handle, package RX>

CL-USER> (defvar *re* (rx:make-regex "[0-9]+"))
#<REGEX live gen 1 {1002934303}>

CL-USER> (rx:regex-is-match *re* "abc123")
T
CL-USER> (rx:regex-count *re* "1 22 333")
3
CL-USER> (rx:regex-replace-all *re* "a1b22" "#")
"a#b#"

;; iterate matches straight into a Lisp closure
CL-USER> (let ((matches '()))
           (rx:regex-for-each-match *re* "x1 y22 z333"
                                    (lambda (m) (push m matches)))
           (nreverse matches))
("1" "22" "333")

;; full unicode, both directions
CL-USER> (rx:regex-count (rx:make-regex "[가-힣]+") "한글 and 러스트 here")
2
```

## 3. Errors are conditions

A bad pattern doesn't crash anything — Rust's `Err` arrives as a
`rulisp:rust-error` (with a `use-value` restart), carrying regex's
excellent message:

```lisp
CL-USER> (rx:make-regex "(unclosed")
;; Debugger: RULISP:RUST-ERROR
;;   Rust error Error in rx:make-regex: regex parse error:
;;       (unclosed
;;       ^
;;   error: unclosed group
```

A Rust panic would arrive as `rulisp:rust-panic` the same way — the image
survives both. Error types you name in your `Result`s (other than the
generic `rulisp::Error`) become their own condition classes, e.g. a
`ParseError` becomes `rx:parse-error`, a subclass of `rulisp:rust-error`.

## 4. Edit Rust, reload, keep your REPL

```lisp
;; ... edit src/lib.rs, then:
CL-USER> (rulisp:use-crate #p"~/src/rx/")
#<CRATE "rx" gen 2 ...>

CL-USER> (rx:regex-is-match *re* "1")   ; handle from generation 1
;; Debugger: RULISP:STALE-HANDLE-ERROR — handle gen 1, crate gen 2
CL-USER> (rulisp:free *re*)             ; still safely freeable
T
```

Old generations stay loaded (never `dlclose`d), so stale handles fail
politely and can always be freed. `rulisp:free` is optional — the GC
finalizer releases unreachable handles too.

## 5. Fitting your API into v1

The v1 type vocabulary: integers, floats, `bool`, `&str`/`String`, opaque
handles (`&self` methods + constructors), and synchronous same-thread
callbacks. Patterns for things it doesn't have yet:

- **`Option<T>`** — supported (since 0.2): Lisp NIL ↔ None for scalar,
  string and byte payloads (`rx:regex-first-match` returns the match or
  NIL). `Option<bool>` is rejected — nil can't distinguish None from
  Some(false).
- **Binary data** — `&[u8]` parameters and `Vec<u8>` returns cross as
  `(unsigned-byte 8)` vectors (the `:bytes` type, since 0.2).
- **Iterators/collections** — either a callback (as `for_each_match`
  above) or a handle wrapping the collection with accessor methods.
- **`&mut self`** — never: use interior mutability (`Mutex`, atomics);
  concurrent calls on one handle are part of the thread contract.

When NOT to use rulisp: if you need crash isolation (a misbehaving native
library must not be able to take the Lisp image down), run the Rust side
out of process instead — in-process FFI trades that isolation for
~50ns calls. See BOUNDARY.md for the full contract.

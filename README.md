# rulisp

**Write Rust, call it from Common Lisp.** rulisp is the missing
PyO3/rustler-style bridge for CL: annotate plain Rust with a couple of
macros, build a cdylib, and load it from the REPL as an idiomatic Lisp
package — CLOS handles, typed conditions, GC finalizers, restarts, and
live reload included.

```rust
use rulisp::prelude::*;

#[rulisp::handle]
pub struct WordBag { words: Mutex<Vec<String>> }

#[rulisp::export]
impl WordBag {
    #[rulisp(constructor)]
    pub fn new() -> WordBag { WordBag { words: Mutex::new(Vec::new()) } }

    pub fn add(&self, word: &str) -> Result<(), Error> {
        if word.is_empty() { return Err(Error::msg("empty word not allowed")); }
        self.words.lock().unwrap().push(word.to_owned());
        Ok(())
    }

    pub fn len(&self) -> u64 { self.words.lock().unwrap().len() as u64 }
}

#[rulisp::export]
pub fn greet(name: &str) -> String { format!("Hello, {name}!") }

rulisp::module! {
    name: "wordbag",
    handles: [WordBag],
    fns: [greet, WordBag::new, WordBag::add, WordBag::len],
}
```

```lisp
CL-USER> (asdf:load-system :rulisp)
CL-USER> (rulisp:use-crate #p"~/src/wordbag/")   ; cargo build + load
#<RULISP:CRATE "wordbag" gen 1 abi 1 :: 4 fns, 1 handle, package WORDBAG>

CL-USER> (wordbag:greet "리스퍼")
"Hello, 리스퍼!"

CL-USER> (defvar *bag* (wordbag:make-word-bag))
#<WORDBAG:WORD-BAG live gen 1 {100A3C2E13}>

CL-USER> (wordbag:word-bag-add *bag* "hello")
CL-USER> (wordbag:word-bag-len *bag*)
1

;; edit Rust, rebuild, reload — without restarting the image:
CL-USER> (rulisp:use-crate #p"~/src/wordbag/")
#<RULISP:CRATE "wordbag" gen 2 ...>
```

## How it works

The macros generate `extern "C"` shims (panic-catching, status codes,
`(ptr,len)` UTF-8 strings, opaque handles) **plus an s-expression manifest
embedded in the cdylib**. The CL side dlopens a unique copy of the library,
reads the manifest, and generates wrappers at load time — `defun`s, CLOS
handle classes, typed conditions from your Rust error types, and
`trivial-garbage` finalizers. No C headers, no hand-written FFI on either
side, and the bindings are derived by construction from the exact library
that was just loaded.

The hard problems are handled structurally, not by convention:

- **Panics** become `rulisp:rust-panic` conditions; `panic = "abort"`
  builds fail to compile.
- **Handles** are gated by a state machine (in-flight counting + deferred
  free): double frees, use-after-free, free-during-call races, stale
  handles after reload or image restore — all signal named conditions
  instead of corrupting memory.
- **Callbacks** are borrowed, same-thread, lifetime-pinned (`!Send`):
  storing one is a compile error. A Lisp condition tunnels through Rust
  (destructors run) and re-signals as the *same object*.
- **Live reload** never calls `dlclose` and always dlopens a fresh copy —
  the reload cannot lie.
- **Image dump/restore** (`save-lisp-and-die`) invalidates every pre-dump
  handle via a session counter and regenerates all bindings on startup.

The full contract is in [BOUNDARY.md](BOUNDARY.md); architecture and
rationale in [DESIGN.md](DESIGN.md) (Korean).

## Status

v0.1.0. Tested: SBCL 2.1+ and Clozure CL 1.13 on Linux x86-64
(101/99 checks green respectively — races, nested callbacks, reload,
dump/restore, 10k-op fuzz). macOS is expected to work (target checks and
dylib handling are in place) but not yet CI-verified. Windows: v1 does not
support it.

Requirements: a Rust toolchain (`cargo`), CFFI-capable Lisp, Quicklisp
(deps: cffi, babel, trivial-garbage, bordeaux-threads).

```sh
make test-m4    # full gate: cargo tests + all suites on SBCL
make test-ccl   # same suites on Clozure CL
```

## Scope (v0.1)

In: scalars, `bool`, `&str`/`String`, opaque handles (`&self` methods,
constructors), synchronous same-thread callbacks, `Result` errors → typed
conditions, live reload, image dump/restore, `use-value`/`retry-build`
restarts.

Out (v0.2 candidates, wire-compatible): `Vec<u8>`/`:bytes`/`Option`,
constructor `&key` arguments, async/stored callbacks, Windows,
prebuilt-binary distribution ([docs/distribution.md](docs/distribution.md)).

rulisp is for writing glue crates — it does not auto-bind arbitrary
existing crates, by design (neither does PyO3).

## License

MIT

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

**Start here:** [docs/installation.md](docs/installation.md) (Linux/macOS
setup, dependencies), then [docs/quickstart.md](docs/quickstart.md) —
wrapping the real `regex` crate in 10 minutes (the finished example is
[`examples/rx/`](examples/rx/)). [docs/usage.md](docs/usage.md) explains
the two ways to consume rulisp — running a prebuilt glue library (no Rust
toolchain needed) vs building your own. For something bigger,
[`examples/wasm/`](examples/wasm/) gives Common Lisp a WebAssembly runtime
in ~190 lines of glue: load `.wat`/`.wasm` modules from the REPL, call
their exports under a fuel-metered CPU budget (runaway guest code traps as
a condition instead of hanging the image), move byte buffers in and out of
the guest's linear memory (bounds-checked; out-of-bounds is a condition),
wire host functions so GUEST code calls straight into your Lisp closures
(stored callbacks; a condition in the closure becomes a guest trap), and
watch wasm traps arrive as Lisp conditions (built on the
signal-handler-free `wasmi` interpreter — see BOUNDARY.md §7 for why that
matters). The full contract is in [BOUNDARY.md](BOUNDARY.md);
architecture and rationale in [DESIGN.md](DESIGN.md) (Korean). Release
history: [CHANGELOG.md](CHANGELOG.md). Reporting a vulnerability and the
threat model: [SECURITY.md](SECURITY.md).

## Status

0.3.0. CI-verified matrix: SBCL on Linux x86-64, macOS arm64 and
Windows x86-64, Clozure CL 1.13 on Linux x86-64, and ECL 21+ on Linux
(races, nested callbacks, reload, dump/restore, 10k-op fuzz — all
green). ECL notes: a C toolchain is required for callbacks (rulisp
natively compiles trampolines to dodge an upstream GC bug we root-caused
— docs/upstream/ecl-dynamic-callback-gc.md), and foreign-thread stored
callbacks are unsupported there.

Versions up to 0.2.1 have a soundness hole (issue #1: an explicit
`'static` in an export signature could retain a Lisp-owned buffer past
the call) and are yanked — depend on 0.3.0.

Requirements: a Rust toolchain (`cargo`), CFFI-capable Lisp, Quicklisp
(deps: cffi, babel, trivial-garbage, bordeaux-threads).

```sh
make test-m4    # full gate: cargo tests + all suites on SBCL
make test-ccl   # same suites on Clozure CL
```

## Scope (v0.1)

In: scalars, `bool`, `&str`/`String`, `&[u8]`/`Vec<u8>` byte buffers,
`Option<T>` (NIL ↔ None), `&[scalar]`/`Vec<scalar>` vectors, opaque
handles (`&self` methods, constructors), borrowed same-thread callbacks
AND stored any-thread callbacks (`StoredCallback` + `rulisp:callback`
tokens — fail-safe lifetime, verified cross-thread on SBCL and CCL),
`Result` errors → typed conditions, prebuilt-blob loading
(`load-blob-crate`, no Rust toolchain needed), live reload, image
dump/restore, `use-value`/`retry-build` restarts.

Out for now — see [ROADMAP.md](ROADMAP.md): `Vec<String>`/nested
containers, multiple return values, non-SBCL image dump.

rulisp is for writing glue crates — it does not auto-bind arbitrary
existing crates, by design (neither does PyO3).

## License

MIT

# Two ways to run Rust from Lisp

rulisp has two entry points, one per situation:

| You have… | You need | Entry point |
|---|---|---|
| **A prebuilt glue library** (`libmylib.so` someone built for you) | Lisp + Quicklisp + rulisp. **No Rust toolchain.** | `rulisp:load-crate` |
| **Rust source you're writing** (your own glue crate) | the above **+ cargo** | `rulisp:use-crate` |

They connect: `use-crate` = `cargo build` + `load-crate`. The `.so` that
case B builds is exactly what you hand to a case-A user.

```
case B (author):  cargo build ──> target/debug/libmylib.so ──┐
                       │                                      │ ship this file
                       └─ use-crate = cargo build + ┐         ▼
case A (user):                          load-crate ◄┴── libmylib.so   (no Rust needed)
```

## Case A — running a prebuilt library

Someone built the glue crate for you — a teammate, a CI pipeline, blobs
committed in a library's repo (see [distribution.md](distribution.md)).

```lisp
(ql:quickload :rulisp)

;; dlopen → read the embedded manifest → generate bindings, all at load time
(rulisp:load-crate #p"/opt/libs/libmylib.so")
;; => #<CRATE "mylib" gen 1 abi 1 :: 12 fns, 2 handles, package MYLIB>

(mylib:do-something "input")
```

When the artifacts follow the blob naming convention
(`lib<name>-<os>-<arch>.<ext>`, e.g. `libwordbag-linux-x86_64.so` — what
`.github/workflows/blobs.yml` produces), one call picks the right file for
the host, with a clear condition when the platform isn't covered:

```lisp
(rulisp:load-blob-crate #p"/path/to/blobs/" "mylib")
```

Two things to know:

1. **Not any Rust `.so` works.** The library must be a rulisp glue crate —
   built with `#[rulisp::export]` + `rulisp::module!`, which embeds the
   manifest the loader reads. Anything else is refused with
   `rulisp:abi-mismatch-error` ("not a rulisp crate"). To use an arbitrary
   existing crate (say, an ML or compression library), *someone* writes the
   glue crate once — that's case B.
2. **The artifact is platform-specific.** A Linux x86-64 `.so` won't load
   on macOS; rulisp's `:target` check refuses a mismatched artifact with a
   clear condition instead of an obscure dlopen error.

## Case B — building your own

Full walkthrough: [quickstart.md](quickstart.md). The short version —
Rust side:

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
rulisp = "0.4"          # from crates.io
regex = "1"             # whatever you're wrapping
```

```rust
use rulisp::prelude::*;

#[rulisp::export]
pub fn greet(name: &str) -> String { format!("Hello, {name}!") }

rulisp::module! { name: "mylib", handles: [], fns: [greet] }
```

Lisp side — build and load in one call, rebuild-and-reload the same way
without restarting the REPL:

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate #p"~/src/mylib/")    ; cargo build + load-crate
(mylib:greet "world")                  ; => "Hello, world!"
;; edit Rust, then again:
(rulisp:use-crate #p"~/src/mylib/")    ; generation 2, old handles refuse politely
```

A failed build signals `rulisp:build-error` carrying cargo's stderr, with
a `retry-build` restart.

## High-frequency events: the queue-polling pattern

Stored callbacks run your closure on whatever thread Rust invokes from.
For high-frequency event streams (async runtimes, watchers), keep the
callback body minimal — push into a queue, process from a Lisp thread:

```lisp
(defvar *events* '())
(defvar *events-lock* (bt:make-lock))

(mylib:on-event (rulisp:callback
                  (lambda (x)
                    (bt:with-lock-held (*events-lock*)
                      (push x *events*)))))

;; drain from any Lisp thread, at your own pace
(defun drain-events ()
  (bt:with-lock-held (*events-lock*)
    (shiftf *events* '())))
```

This keeps foreign-thread time short and moves real work onto threads you
control. (A dedicated helper was considered and skipped — the pattern is
five lines of user code.)

## Why rulisp lives in two package registries

This mirrors how PyO3 works (PyO3 is on crates.io, not PyPI):

- **crates.io** (`rulisp`, `rulisp-macros`, `rulisp-runtime`) serves
  **case-B authors** at *compile time*: cargo fetches them to expand the
  macros and statically link the runtime into your `.so`.
- **Ultralisp/Quicklisp** (the `rulisp` ASDF system) serves **Lisp users**
  at *load/run time*: the loader that dlopens artifacts and generates
  bindings.
- The glue `.so` itself plays the role of Python's wheel: once built, it
  carries everything Rust-side inside it, which is why case A needs no
  Rust toolchain at all.

## Reading a crate at the REPL

Every generated function and handle class carries a docstring, and a
crate answers `describe`:

```lisp
CL-USER> (documentation 'rx:make-regex 'function)
"(rx:make-regex pattern)
Rust: Regex::new(pattern: :string) -> rx:regex, Err(Error)
Signals: rx:rust-error (a rulisp:rust-error) on Err."

CL-USER> (describe (rulisp:use-crate #p"examples/rx/"))
#<RULISP:CRATE "rx" gen 1 ...> is a rulisp crate.
  Package:        RX
  Generation:     1 (session 0)
  Artifact:       .../examples/rx/target/debug/librx.so
  Built with:     rulisp 0.4.0 (this loader: 0.4.0)
  ...
  Exports (5):
    (rx:make-regex pattern)
    ...
```

A `///` comment on an exported Rust fn or a `#[rulisp::handle]` struct
leads its docstring — the macros carry it in the manifest as `:doc`.

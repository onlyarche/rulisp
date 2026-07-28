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
rulisp = "0.1"          # from crates.io
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

# Changelog

Notable changes per release. Versions are shared by the Rust crates
(`rulisp`, `rulisp-macros`, `rulisp-runtime` on crates.io) and the ASDF
system. The C ABI has its own version, checked at load time: **ABI 1 since
0.1.0, unbroken** — every type added since is wire-additive.

## 0.2.1 — 2026-08-03

### Fixed
- crates.io pages rendered no README: the file lives at the workspace root
  and no crate declared `readme`, so it was never packaged. Crate metadata
  comes from the published artifact, hence a release.

## 0.2.0 — 2026-07-29

### Added
- **`:bytes`** — `&[u8]` parameters and `Vec<u8>` returns as
  `(unsigned-byte 8)` vectors; the `:string` wire minus UTF-8 validation.
- **`(:option T)`** — `Option` of scalars, strings and byte buffers, both
  directions; Lisp `NIL` ↔ `None`. `Option<bool>` is a compile error (nil
  cannot distinguish `None` from `Some(false)`).
- **`(:vec S)`** — `&[scalar]` / `Vec<scalar>` as element-counted buffers,
  freed via `dealloc(ptr, len * size, align)`; Lisp gets specialized arrays.
- **Stored callbacks** — `StoredCallback<A>` plus `rulisp:callback` tokens:
  a registered Lisp closure Rust may keep, clone and invoke later from any
  thread. Fail-safe lifetime — after the token is unregistered or
  garbage-collected, invocation returns an error instead of dangling.
  Cross-thread invocation verified on SBCL and CCL.
- **`rulisp:load-blob-crate`** and the `lib<name>-<os>-<arch>.<ext>`
  convention for prebuilt artifacts (no Rust toolchain needed), with
  `.github/workflows/blobs.yml` building them on release tags.
- Examples: `examples/rx` (the `regex` crate) and `examples/wasm` — a
  WebAssembly runtime for CL with fuel-metered CPU budgets, bounds-checked
  linear-memory access, and host functions that call back into Lisp.
- Docs: quickstart, installation, usage (the two consumption paths),
  distribution, roadmap.

### Fixed
- **ECL is now fully supported.** Callbacks segfaulted after any GC because
  of an apparently unreported ECL bug — `si:make-dynamic-callback` keeps its
  libffi closure metadata only in memory the Boehm GC does not scan
  (writeup: `docs/upstream/ecl-dynamic-callback-gc.md`). rulisp now compiles
  trampolines natively on ECL. Full suite green on ECL 21.2.1; one
  documented limitation remains — ECL cannot adopt foreign threads, so
  stored callbacks must be invoked from Lisp-visible threads there.

### Notes
- Constructor `&key` arguments were dropped from the plan: dogfooding showed
  positional arguments read better at the 0–2 argument sizes real
  constructors have. May return as an opt-in attribute.

## 0.1.0 — 2026-07-15

First release: the frozen boundary (ABI 1) and the PyO3-style workflow.

### Added
- `#[rulisp::handle]`, `#[rulisp::export]`, `rulisp::module!` — plain Rust
  in, `extern "C"` shims plus an embedded s-expression manifest out.
- Load-time binding generation on the CL side: `defun`s, CLOS handle
  classes, typed conditions from Rust error types, GC finalizers.
- Handle safety as a state machine: in-flight counting with deferred free
  makes double-free, use-after-free and free-during-call unreachable;
  handles are gated against the generation of the wrapper that made them.
- Panics become `rulisp:rust-panic`; `panic = "abort"` builds fail to
  compile. Borrowed callbacks tunnel Lisp conditions back without unwinding
  Rust frames.
- Live reload (unique-copy `dlopen`, never `dlclose`) and
  `save-lisp-and-die` support (session counter invalidates pre-dump state,
  bindings regenerate on restore).
- `rulisp:use-crate` (cargo build + load) with `build-error` and a
  `retry-build` restart; `use-value` restarts on failed calls.
- Verified on SBCL and Clozure CL, Linux and macOS.

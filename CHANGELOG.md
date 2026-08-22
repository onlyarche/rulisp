# Changelog

Notable changes per release. Versions are shared by the Rust crates
(`rulisp`, `rulisp-macros`, `rulisp-runtime` on crates.io) and the ASDF
system. The C ABI has its own version, checked at load time: **ABI 1 since
0.1.0, unbroken** — every type added since is wire-additive.

## Unreleased (0.4 development)

### Added
- **BOUNDARY.md §12: the conformance table.** Every normative claim in
  §1–§11 (103 rows) classified as compile error, runtime check, test,
  documented-UB-by-design, or gap — with verified citations. The two
  remaining gaps are scheduled v0.4 items and say so in the table.
- Eight new conformance tests (`:rulisp-v04`), closing every prose-only
  claim the sweep found: swallowed `CallbackError` discards the stash;
  swallow-then-fail re-signals the original condition (status 4); a panic
  in a `*_free` shim is caught and swallowed (new `Grenade` fixture handle
  whose `Drop` panics); a poisoned mutex reports `rust-panic` on the next
  lock; `last_error` is thread-local AND per-library (concurrent failures
  in wordbag and rx never cross); out-params survive an ERR return
  untouched (FFI-level sentinel test); ECL's missing-C-compiler failure is
  the named `manifest-error` (injected via `c::*cc*`).
- **`on_dump: <fn>` in `rulisp::module!`** — a declared, zero-arg shutdown
  export the loader auto-registers as an image-dump hook (new wire-additive
  manifest key `(:on-dump "symbol")`; ABI 1 intact). Hooks run in load
  order; a failing hook is warned and skipped — a dump is never wedged by
  its own cleanup. The manifest refuses a declaration whose function takes
  parameters or returns a value (the call goes through a fixed signature),
  and `module!` rejects it at compile time too. `examples/fetch` converts:
  its hook quiesces every live tokio runtime, and the suite proves the
  whole story by dumping an image with a request in flight and restoring
  it (the two tests the v0.3 risk table promised).
- The dump/restore test (m7) now really runs on CCL — and Windows —
  instead of passing vacuously off SBCL, with a new assertion: a pre-dump
  handle GC'd after restore must not make a foreign call.

### Fixed
- The loader now rejects `(:option :bool)` in a hand-written manifest
  (`option-inner`); previously only the macro refused to emit it.

## 0.3.0 — 2026-08-14

### Added
- **`examples/fetch`** — an async HTTPS client (reqwest + rustls on tokio),
  the v0.3 flagship. Pull-based: `Client` owns the runtime, admission
  semaphore and ready queue; `Req` owns one exchange; bodies are pulled as
  `:bytes` or streamed to a file; headers cross as the raw CRLF field block
  both ways. It needs **no new boundary feature** — no wire change, no ABI
  bump. Ships with a Lisp veneer (conditions with a kind slot, restarts,
  `with-client`), a hermetic loopback test server, and `audit.sh`, an
  executable BOUNDARY §7 check.
- `make bench` — a benchmark suite for the boundary paths.
- **Windows support.** The loader is abstracted over `dlopen`/`dlsym` and
  `LoadLibrary`/`GetProcAddress`, `uintptr` is derived from the pointer
  size (naming a C type is wrong on LLP64), and artifact naming knows
  Windows drops the `lib` prefix. CI runs the full suite there, 177/177.

### Changed
- **Bulk `:bytes`/`:vec` marshalling**: pinned vector + `memcpy`, with the
  inbound side now a true zero-copy borrow. Measured 24× on a 1 MiB byte
  transfer and 307× on a 65k-element `i64` vector.

### Fixed
- **Soundness (issue #1):** an explicit `'static` in an export signature
  compiled cleanly — under `#![forbid(unsafe_code)]` — and let a glue
  crate retain a Lisp-owned buffer past the end of the call (use after
  free). The borrowing helpers' lifetimes were unconstrained, so the
  caller's signature chose them. Fixed at both layers: the macro rejects
  any explicit lifetime anywhere in an export signature (`&'static str`,
  `Option<&'static str>`, slices, handle references, `Callback<'static,…>`,
  and the `&'a self` receiver — each pinned by a trybuild test), and the
  helpers now take a per-call `ShimFrame` whose borrow the returned
  lifetime is inferred from, so the guarantee no longer depends on the
  macro remembering to check. Affects 0.1.0–0.2.1.
- Duplicate `:lisp-name` in a manifest silently shadowed one export; now
  rejected before anything is interned.
- `#[rulisp(constructor)]` on a `&self` method dropped the receiver and
  surfaced as a raw `E0061`; now a compile error naming the fix.
- The `Cargo.toml` scraper could not tolerate CR, so `use-crate` failed on
  any CRLF manifest. The tree is also pinned to LF now: a CRLF checkout
  broke the golden byte-identity fixture and turned Lisp format-string
  line continuations into `FORMAT-ERROR`.

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

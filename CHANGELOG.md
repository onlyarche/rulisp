# Changelog

Notable changes per release. Versions are shared by the Rust crates
(`rulisp`, `rulisp-macros`, `rulisp-runtime` on crates.io) and the ASDF
system. The C ABI has its own version, checked at load time: **ABI 1 since
0.1.0, unbroken** — every type added since is wire-additive.

## Unreleased (0.6 development)

### Added
- **The loader's API describes itself, and exports what the docs already
  name.** Fifteen additive exports: `rulisp-version-skew` — the
  style-warning stability.md §7 tells users they may muffle — with its
  three readers, and the eleven condition readers that were internal
  while their siblings were exported (`rust-panic-function-name`,
  `invalid-argument-message`/`-function-name`,
  `invalid-handle-function-name`, `crate-not-loaded-name`/`-message`,
  `build-error-command`, `manifest-error-message`,
  `abi-mismatch-expected`/`-actual`/`-message`): 32 → 47. Every exported
  condition class, `crate` and `callback-token` carry a class
  documentation saying when they are signaled and which restart is
  offered; every exported reader has a docstring;
  `v06.exports-are-documented` keeps it so. `Error::msg`'s Rust doc no
  longer names the nonexistent `<crate>:rust-error`.
### Added
- **Lisp API gate.** `tests/golden/lisp-api.sexp` pins every exported
  symbol of `rulisp` with its kind, its superclasses (classes and
  conditions) or its lambda list (functions); `v06.exported-api-golden`
  compares it on every host — lambda lists exactly on SBCL, by parameter
  names on CCL and ECL. An additive export regenerates the golden in the
  same commit; a removal or a changed signature fails.
### Added
- **Rust API gate.** Every push runs `cargo-semver-checks` over
  `rulisp`, `rulisp-macros` and `rulisp-runtime` against the latest
  crates.io release with `--release-type minor` — the criterion-3
  question, "does this tree break a consumer of the release", asked
  mechanically. `rulisp::runtime` stays public and is checked with the
  rest; hiding it waits for the 1.0 major.
### Added
- **"Required" is a release gate.** The release job refuses to attach
  assets to a tag whose commit's CI run does not have every `(required)`
  job and `MSRV` concluded success — no run, or a run still in progress,
  refuses too, naming the job (`tools/required-ci-green.sh`, self-testable
  with an injected job listing). `skip-ci-gate` is the documented
  override for a re-run and prints a warning. Until now a tag on a red
  commit produced a release with twelve audited assets.
### Added
- **The audit reads every format from every host — the last BOUNDARY
  §12 gap closes.** `tools/rulisp-audit.sh` dispatches on the artifact's
  magic, not on `uname`: ELF through `nm`, Mach-O through Apple's `nm` or
  rustup's `llvm-nm`, PE through rustup's `llvm-readobj --coff-imports`
  (`rustup component add llvm-tools`), sweeping Windows' analogues of a
  signal handler (ucrt `signal`/`raise`, `SetConsoleCtrlHandler`, the
  exception-filter and vectored-handler installers). A format it cannot
  read fails instead of printing SKIP. The Windows CI job runs `make
  audit` with the self-test (the fixture DLL must be rejected), and the
  release job re-audits all twelve assets as downloaded, on Linux, before
  attaching them; `workflow_dispatch` gained `publish: false` for a
  build-and-audit-only run.
### Added
- **Cross-version gates, pinned to the previous release.** `make compat`
  loads this tree's `wordbag` with the v0.5.0 loader (any warning but
  `rulisp-version-skew` is an error) and runs the v0.5.0 test suite
  against this tree's loader, on every push; the release-asset step is
  pinned to v0.5.0 so it stays old-crate/new-loader after the next
  release. `v06.abi-mismatch-refused` loads `tests/abi-fixture`, whose
  `abi_version()` answers 2, and expects the refusal before a byte of
  manifest is read — the §12 row that said "no suite test simulates a
  mismatch" now cites it.

### Changed
- **`crate-generation` is a reader.** The slot was declared with an
  accessor, so `(setf (rulisp:crate-generation crate) 0)` was an exported
  function that no doc, test or example used — and it defeated the
  generation gate: reset the counter and reload, and a handle from the
  old library passed into the new one (a Box from one library copy
  dereferenced by another's shim). The writer is gone; the reader is
  unchanged, and `v06.crate-generation-is-read-only` checks that no
  exported symbol names a setf function. Classified under stability.md
  §4 (a soundness fix, forward), not §3: a style-warning stage would keep
  the hole open one more minor. The v0.5.0 suite, run against this
  loader by `make compat`, only ever read the generation.
### Changed
- **`m4.gc-finalization` no longer assumes no collection runs inside its
  constructor loop.** It dropped each of 1000 handles as it made them and
  then asserted all 1000 live; a nursery GC inside the loop finalizes
  some first — the Linux aarch64 job's one failure, reproduced on x86-64
  with a small nursery. The test now holds the handles while it counts
  them, then releases every reference and collects. The arm job's
  promotion streak restarts here.

### Fixed
- **`Option<f32>` / `Option<f64>` NIL is None, not a host type error.**
  For an optional float parameter the wrapper put the integer 0 in the
  value slot when the argument was NIL, and SBCL's and CCL's foreign-call
  checks refused a fixnum for `:double`/`:float`; README and quickstart
  promised NIL ↔ None. The placeholder is typed now; `wordbag` gained
  `opt_scale`/`opt_scale32` (manifest golden co-updated) and
  `v06.option-float-nil-is-none` pins it on every host.
- **A cargo that cannot be run is a `build-error`, on every host, with a
  `retry-build` that looks cargo up again.** `use-crate` promised
  `build-error` with a `retry-build` restart, but a cargo that could not
  be executed at all escaped as the host's own error on SBCL, arrived as
  a `build-error` with an empty stderr on CCL, and the restart was inert
  everywhere: cargo was looked up once, outside the restart loop, so
  setting `RULISP_CARGO` from the debugger and retrying re-ran the old
  path. Now the exec failure is a `build-error` carrying the host's
  message, an empty stderr is replaced by the exit status and the
  program name, and each retry looks cargo up again. Migration: code
  that handled the host's error class around `use-crate` handles
  `rulisp:build-error`.
### Fixed
- **A crate whose reload failed on image restore could crash the next
  dump.** `%stub-crate` replaced the generated functions but left the
  dumped image's library handle and dump-hook pointer on the crate
  object, so `%run-crate-dump-hooks` — what the next `uiop:dump-image`
  runs first — called into the dead mapping (SBCL: `CORRUPTION WARNING
  … Memory fault`; found by the v0.6 panel, docs/design/v06-plan.md item
  1). Every foreign pointer is dropped with the functions now; the crate
  is inert until `reload-crate` succeeds (which un-stubs it), `describe`
  says so with the reason, and BOUNDARY §10 states the rule. The restore
  hook also catches any `serious-condition` from the reload, not only
  `error` — on ECL a host fault inside `dlopen` is a storage-condition
  and used to escape the hook with the crate left half-alive.

## 0.5.0 — 2026-09-04

### Added
- **`:string` ASCII fast path** — both directions of a `:string` now take
  a typed check-and-store loop while the text is ASCII and hand the same
  bytes to babel at the first char/byte ≥ 128, after a peek at the first
  one so text that is non-ASCII from the start (CJK, say) allocates
  nothing extra. Host-neutral, no wire change, the copy contract of
  BOUNDARY §4 untouched — zero-copy `:string` stays refused. A 64 KiB
  ASCII round trip drops from ~1 ms to ~0.32 ms on the benchmark host
  (docs/benchmarks.md); non-ASCII text costs what it did. New
  `v05.utf8-fastpath-boundary` walks the seam (empty, DEL, code 128,
  interior NUL, Latin-1 range, 4-byte chars first/last, fill-pointer and
  base strings) through wordbag's echo on all three hosts, and the bench
  gains an rx "count over 1 MiB" row: a real `&str` consumer.
- **Releases with audited assets** — every `v*` tag builds the four
  examples in the release profile on each required host (Linux x86-64,
  macOS arm64, Windows x86-64), runs `tools/rulisp-audit.sh` over each
  (Windows: the script prints SKIP, recorded as a gap in BOUNDARY §12),
  and attaches the twelve blobs, named for `load-blob-crate`, to a
  GitHub Release whose body is that version's CHANGELOG section.
  `make check-versions` holds every site that repeats the version to
  one string; docs/releasing.md is the checklist around it.
- **MSRV** — `rust-version = "1.78"` in the three crates, checked in CI
  on exactly that toolchain over the macros, the runtime, `rulisp` and
  the code the macros generate for `wordbag`.
- **Linux aarch64** — `SBCL / Linux aarch64 (best-effort)` on GitHub's
  arm runners: the loader's aarch64 paths (the target check, the blob
  suffix) execute for the first time. Promotion follows the written
  procedure; the `linux-arm64` release asset comes with it.
- **docs.rs front door** — the three macros document the full attribute
  grammar and the closed type vocabulary, every public item in `rulisp`
  has a doc, the crate-level example is a compiled doctest, and CI builds
  the docs with `missing_docs` and broken links as errors.
- **Docstrings, `describe`, and `:doc`** — the REPL front door. Every
  generated function and handle class now has a docstring synthesized
  from the manifest (the Lisp call shape, the Rust signature, and which
  condition an `Err` becomes); `(describe crate)` prints where the crate
  came from, its generation, versions, dump hook, handle classes and every
  export's signature. A glue crate's `///` comments travel too: the macros
  put them in the manifest as `:doc` (an enhancement key — older loaders
  ignore it) and they lead the docstring. `#.` inside a `:doc` is text,
  never code: the loader's reader runs with `*read-eval*` off.
- **`:rulisp-version` in the manifest, and the key-class rule** (BOUNDARY
  §11): a load-bearing manifest key raises `:schema`; an enhancement key
  rides the ignore-unknown-keys rule. Every crate now records the rulisp
  it was built with, and a loader whose major.minor is older signals
  `rulisp-version-skew` (a `style-warning`) and loads anyway. Stated
  plainly, because this rule is new: a crate built with 0.4 or later that
  declares `on_dump` loads cleanly on a **0.3** loader with its dump hook
  silently dropped — `:on-dump` predates the rule and stays at `:schema` 1,
  since a retroactive bump would refuse every newer crate on the 0.4.0
  loaders that support it fully. Upgrade the loader.
- **docs/stability.md** — what is stable and what 1.0 will promise: the
  four versioned surfaces (Rust API, the 32-symbol Lisp API, the manifest
  schema, the C ABI) and what breaks each; semver and deprecation policy;
  host support defined as the required CI matrix with a written
  promotion/demotion procedure; the manifest key-class rule; the 1.0 exit
  criteria; the Quicklisp prerequisites. CI now proves the system loads
  with no cargo on PATH.

### Fixed
- **Docstrings named a symbol that does not exist** — for a
  `Result<_, Error>` export the synthesized "Signals:" line said
  `<crate>:rust-error`; the condition is `rulisp:rust-error` itself.
  `describe` listed a `///`-documented export by its first doc line
  instead of its call shape; it now prints the call shape for every
  export. Both surfaced when the docs audit compared usage.md's
  transcript with the loader's real output.
- **Audit false positive on macOS** — `tools/rulisp-audit.sh` matched an
  inner `_signal` (`_dispatch_semaphore_signal`, imported by every macOS
  artifact) as a signal import; only a leading underscore is Mach-O's now,
  and the self-test checks the pattern both ways.
- **On CCL, lending a buffer to Rust stopped the world.** CFFI's
  `with-pointer-to-vector-data` is `ccl:with-pointer-to-ivector` there,
  whose body runs under `without-gcing` — so every `:string`, `:bytes`
  and `:vec` argument suspended garbage collection for every thread for
  the whole export, callbacks included (measured: 0 collections
  completed on another thread during a 600 ms borrow; ~30 unpinned). The
  loader now pins only long enough to memcpy into a heap buffer on CCL
  and lends the copy. SBCL keeps the zero-copy borrow; ECL's pin never
  inhibited GC. `v05.pin-does-not-stop-the-world` proves it on all three.

### Changed
- **Docs claim audit** — every capability, host and performance claim in
  README and the docs pages (371 of them) now has a citation in
  docs/claims.md or was corrected: the handle bullet (a second free is
  refused, a racing free is deferred), "Scope (v0.1)" and the stale
  "non-SBCL image dump" out-list, the quickstart's error-class rule and
  its ~50 ns figure, usage.md's `:target`-check story and its Quicklisp
  mention, benchmarks.md's 16× comparison, installation.md's
  cargo-not-found and Windows cache-path rows. One support table (README
  §Status) equals the required CI matrix; benchmarks.md carries SBCL,
  CCL and ECL columns. CI now also loads rulisp from Quicklisp's
  local-projects and `load-blob-crate`s a downloaded release asset, as
  the pages instruct.
- **The fuzzers can fail now.** `m4h.thread-race` and
  `m4h.random-op-sequence` asserted only "no unexpected condition"; a
  leaked in-flight count or a free that never reached Rust passed. Both
  now reconcile every generation's live-handle and live-allocation
  counters at the end (captured as wrapper closures, so generations
  reloaded mid-run reconcile against their own library copy), take their
  seed from `RULISP_FUZZ_SEED` (a `workflow_dispatch` input in CI) and
  print it on failure. Verified by mutation: with half of all frees
  skipped, the race fuzzer reports the leak. New `m4h.reload-under-load`
  proves BOUNDARY §4's cross-reload claim — strings round-tripped by four
  threads across three live reloads are released through their own
  generation's dealloc; every generation ends at zero.
- The fetch suite runs in CI (SBCL/Linux and CCL/Linux required; macOS
  best-effort) — the 23 tests BOUNDARY §12 cites had only ever run on the
  maintainer's machine. Its first run on CCL fixed two host assumptions in
  the tests themselves.

## 0.4.0 — 2026-09-02

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
- **docs/benchmarks.md** — a dated, release-profile baseline with the
  method; every number quoted in this changelog traces to it.
- **The ECL CI job is required** (was best-effort): 24 consecutive green
  runs since the 0.2 trampoline fix, now including the program-op
  deployment smoke. The workflow documents the demotion procedure.
- **`tools/rulisp-audit.sh`** — BOUNDARY §7 as a command for any glue
  crate (signal-disposition imports on the artifact, tokio signal/process
  features, `block_on`), run over every example by `make audit` in CI. A
  self-test builds a library that deliberately imports `signal()` and
  requires the audit to reject it, so the gate cannot go inert unnoticed
  again. fetch's `audit.sh` is now a wrapper adding its OpenSSL rule.
- **`#[rulisp(constructor, name = "…")]`** — an explicit Lisp name for a
  constructor. Load-bearing since 0.3 made duplicate `:lisp-name` a hard
  error: two constructors on one type both derived `make-<type>`, so a
  second constructor was inexpressible. The attribute grammar is now
  strict — a misspelled key, a non-string name, a name with reader syntax,
  or `name` on a non-constructor are compile errors (previously unknown
  keys were silently ignored).
- **ECL deployment story** (docs/distribution.md Pattern B′): ECL has no
  image dump; applications ship as `asdf:program-op` executables. The
  documented recipe (`:no-uiop t` because the distro ECL cannot satisfy
  ASDF's default static link of `cmp` — no `libcmp.a` — a prologue
  `require`, an explicit epilogue entry call, and the dependencies loaded
  before `program-op`, which the bundled ASDF 3.1.8.8 cannot build from a
  cold cache) is exercised by `tests/ecl-program`, a minimal consumer the
  ECL CI job builds and runs (`make test-ecl-program`).
- The dump/restore test (m7) now really runs on CCL — and Windows —
  instead of passing vacuously off SBCL, with a new assertion: a pre-dump
  handle GC'd after restore must not make a foreign call.

### Fixed
- **Two processes sharing one crate cache could crash each other.** The
  cache copy was named `<crate>-c<n>-<universal-time>` with `n` counted per
  process, so two instances started in the same second wrote the same
  file, and `copy-file` rewrote a library the other process had already
  mapped — a segmentation fault (found by the ECL deployment verification,
  reproduced 5/5). Copies now carry a per-process tag (pid, or a random
  tag where the host has none), recomputed on image restore; the sweep
  deletes this process's older generations immediately and other
  processes' copies only after an hour, so it can no longer unlink a copy
  another process is about to `dlopen`.
- A failed `dlopen` names the artifact the user asked for, not only the
  cache copy.
- rulisp's load-time compiles are quiet now: on ECL, `compile` prints
  per-function notes, so a deployed program printed dozens of lines every
  time it loaded a crate.
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

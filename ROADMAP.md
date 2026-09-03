# Roadmap

## v0.5 — a 1.0 candidate a stranger can verify

Make every front door true — CI runs what BOUNDARY §12 cites, releases
exist, docs.rs and the REPL explain themselves — fix the two defects §12
cannot see, and write down what 1.0 promises. No new boundary feature, no
flagship (still no external request; the tracker holds one closed
soundness issue). ABI 1 frozen; every wire change is an additive manifest
key. Full plan with demand cases, acceptance criteria and cut order:
docs/design/v05-plan.md (three-proposal panel, two verifying judges).

1. **Run the fetch suite in CI** — 23 tests §12 cites as enforcement have
   only ever run on the maintainer's machine.
2. ✅ **docs/stability.md** — the four versioned surfaces, semver and
   deprecation policy, host support = the required matrix with the
   promotion/demotion procedure, the manifest key-class rule, the 1.0 exit
   criteria, and the Quicklisp prerequisites (listed, not scheduled). The
   SBCL/Linux job now proves `(ql:quickload :rulisp)` needs no cargo.
3. ✅ **CCL pin semantics** — confirmed and fixed: with a 4 MiB buffer
   lent for 600 ms, another thread completed 0 collections on CCL (~30
   unpinned); the loader now pins only for a memcpy there. The test
   counts completed collections via the host GC counter — its first
   version counted requests and passed on the broken code, its second
   let a warm-up window through; the shipped one starts counting at the
   call.
4. ✅ **Falsifiable fuzzers** — per-generation live-count reconciliation
   (captured wrappers, so reloaded generations reconcile against their own
   copy), `RULISP_FUZZ_SEED` in messages and as a CI dispatch input, and
   `m4h.reload-under-load` for the §4 cross-reload claim. Mutation-tested:
   skipping half the frees makes the race fuzzer fail.
5. ✅ **Manifest skew rule + `:rulisp-version`** — the key-class rule is
   normative in BOUNDARY §11; every crate records the rulisp it was built
   with, and an older loader warns (`rulisp-version-skew`, a
   style-warning) and loads anyway. The golden carries a placeholder
   version so a release bump does not rewrite it. The 0.3-loader exposure
   of `on_dump` is stated in the changelog rather than re-fixed.
6. ✅ **REPL front door** — all three layers: docstrings synthesized from
   the manifest on every function and handle class, `describe-object` on
   a crate, and Rust `///` carried as the `:doc` enhancement key with a
   proper string escaper in the renderer (the golden now carries nine).
7. ✅ **docs.rs front door** — `///` on the three macros with the
   attribute grammar and the type table, `missing_docs` clean on `rulisp`
   and `rulisp-macros`, a compiled crate-level doctest, `make doc` and a
   CI step with `RUSTDOCFLAGS=-D warnings`.
8. ✅ **Release engineering + Linux aarch64** — every `v*` tag now
   yields a GitHub Release with twelve audited assets (three required
   hosts × four examples, named for `load-blob-crate`; Windows unaudited,
   recorded in BOUNDARY §12) and the CHANGELOG section as body; v0.4.0
   was backfilled the same way and its Linux blob loads. The first macOS
   run found a real audit bug (an inner `_signal` read as a signal
   import). `rust-version = "1.78"` with an MSRV job that also checks
   generated code, `make check-versions` (fails on a skewed site),
   docs/releasing.md, and `SBCL / Linux aarch64 (best-effort)` — green on
   its first run.
9. ✅ **`:string` ASCII fast path** — a typed check-and-store loop in
   both directions, babel from the first char/byte ≥ 128, a peek before
   any allocation so non-ASCII text pays nothing extra: 64 KiB ASCII
   1015 → 318 µs (3.2×), non-ASCII unchanged. Differentially tested
   against babel on all three hosts (no counterexample in ~12k checks)
   and swept adversarially through echo; zero-copy `:string` stays
   refused.
10. **Miri over the generated shims** — optional; cut first.
11. **User-facing docs claim audit, last** — README still says
    "Scope (v0.1)"; every capability claim gets a citation or is deleted.

Not in v0.5 (causes in the plan): a flagship example, vocabulary round 2,
zero-copy `:string`, a retroactive `:schema 2`, print-object polish, a
soak workflow, cargo-fuzz/sanitizers (Miri fits; sanitizers cannot
coexist with SBCL's signal-driven GC), `cargo rulisp new`, LispWorks/
Allegro/ABCL/ocicl, macOS x86_64 blobs, Quicklisp (1.0), constructor
`&key`, push callbacks, dlclose, any ABI bump.

## v0.4 — enforced, everywhere

Issue #1's reporter praised the boundary because "the surrounding
invariants are otherwise enforced rather than merely documented" — and
0.1.0–0.2.1 were yanked over the one claim that wasn't. v0.4 makes that
property total: every normative BOUNDARY.md claim becomes a compile error,
a runtime check, or a non-vacuous test on every claimed host, and the §10
dump discipline becomes structural. ABI 1 stays frozen; nothing here adds
an ECL load-time toolchain requirement. Full plan with demand cases and
acceptance criteria: docs/design/v04-plan.md (scoped by a three-proposal
panel with two verifying judges).

1. ✅ **BOUNDARY conformance sweep** — §12: all 103 normative claims
   classified with verified citations. The six pre-verified prose-only
   gaps got tests, plus two the sweep itself found (per-library
   last_error isolation; loader-side `(:option :bool)` rejection).
2. ✅ **De-vacuous m7** — the dump/restore test now really runs on CCL
   (`uiop:dump-image` → `ccl:save-application`; assertions live in
   `*image-entry-point*` since CCL's toplevel is fixed), plus a new
   finalizer assertion: a pre-dump handle GC'd after restore must not make
   a foreign call. First real CCL execution passed immediately — the
   machinery was portable all along; only the test was missing.
3. ✅ **`on_dump`** — a declared zero-arg shutdown export in
   `rulisp::module!`, auto-registered as a dump hook by the loader
   (wire-additive `(:on-dump "symbol")` key; validated at macro AND
   loader). fetch converted; the flagship test dumps an image with a
   tokio transfer live and restores it — the two tests v0.3's risk table
   promised.
4. ✅ **ECL deploy story** — no `dump-image` exists there (verified);
   `asdf:program-op` is the delivery path. Three traps found and
   documented (docs/distribution.md Pattern B′): the distro ECL cannot
   satisfy ASDF's default static link (its `cmp.asd` names a `libcmp.a`
   the package does not ship), so `:no-uiop t` + a prologue `require`;
   `:no-uiop` also drops the entry-point wiring; and the bundled ASDF
   3.1.8.8 cannot `program-op` the dependencies from a cold cache — load
   them first. `tests/ecl-program` is the smoke consumer, run by the ECL
   job (`make test-ecl-program`). The adversarial verification of this
   item also found a real core bug on every host — two processes sharing
   a cache could crash each other (copy names were unique only per
   process) — and rulisp's load-time compiles went quiet, since a
   deployed ECL program printed fifty compiler notes per crate load.
5. ✅ **`#[rulisp(constructor, name = "…")]`** — wordbag's second
   constructor (`make-word-bag-from`) is the demand case; the attribute
   grammar became strict on the way (misspelled keys used to be ignored
   silently). Oracle, manifest and golden co-updated; trybuild pins the
   four rejection paths.
6. ✅ **Reusable signal-audit tool** — `tools/rulisp-audit.sh`, run over
   all four examples by `make audit` in CI; `tools/audit-fixture` imports
   `signal()` on purpose and the self-test requires the audit to reject
   it. The last GAP row in BOUNDARY §12 closed with it.
7. ✅ **docs/benchmarks.md** — dated, release-profile baseline with host,
   toolchain and raw `make bench` output; the CHANGELOG multipliers trace
   to two of its rows. It also says plainly that `:string` is the slow
   path (UTF-8 codec, deliberately deferred) — pass bulk data as `:bytes`.
8. ✅ **ECL CI promoted to required** — 24 consecutive green runs since
   2026-07-29 (35 days), item 4's program-op smoke included. The workflow
   carries a written demotion procedure so a flake is handled in one
   honest commit, never by quietly flipping a flag.

Not in v0.4 (causes in the plan): boundary vocabulary round 2
(`(:vec :string)`, multiple values, tagged enums), the push/doorbell
callback layer, reload semantics for on_dump, a new flagship example,
print-object polish, LispWorks/ABCL/ocicl, Quicklisp (1.0, user
decision), constructor `&key`, anything that would `dlclose`.

## v0.3 — prove it on something hard, and keep it fast

Theme: v0.1 froze the boundary, v0.2 filled in types and callbacks; v0.3
takes a demanding real consumer and makes the performance claims defensible.
The flagship is an **async HTTPS client** (`examples/fetch`: reqwest +
rustls on a tokio runtime), chosen because CL's TLS story is genuinely
painful and because tokio is the hardest test of the v0.2 thread contract.

A design panel (three independent designs, two judges) settled the API:
**pull-based**, two handles (`Client` owning the runtime + readiness queue,
`Req` per in-flight request), bodies pulled chunk-by-chunk as `:bytes`,
headers crossing as the raw CRLF field block in `:bytes` both ways, every
wait capped in Rust with the loop in Lisp, and a thin pure-Lisp veneer
providing conditions, restarts and `with-client`. Headline finding:

> **It requires zero new boundary features.** No wire change, no ABI bump,
> no new type token. `:bytes` in callback params, `(:vec :string)`,
> core cancellation and `Vec<Vec<u8>>` were each examined and refused with
> cause — the pull design either doesn't need them or is better without.

### Prerequisites (all zero-wire, ABI 1 preserved)
- ✅ **Bulk `:bytes`/`:vec` marshalling** — pinned vector + `memcpy` fast
  paths, element-wise fallback retained. Measured: 1 MiB byte transfer
  **24× faster**, a 65k-element `i64` vector **307× faster**. A flagship
  moving megabyte bodies could not ship on the old marshaller.
- ✅ **Duplicate `:lisp-name` rejected at the manifest** — shipped v0.2.1
  silently shadowed the loser (two `#[rulisp(constructor)]` fns on one type
  both compute `make-<type>`), leaving it unreachable with no diagnostic.
- ✅ **`#[rulisp(constructor)]` on a `&self` method is a compile error**
  with the workaround in the message — it used to drop the receiver and
  surface as a raw `E0061` inside generated code.
- ✅ **Contract text** (BOUNDARY §7/§10): cap blocking waits in Rust,
  refuse re-entry from runtime threads, and the surprising one — dumping
  with live foreign threads succeeds silently, so thread-owning crates need
  an explicit shutdown called from a dump hook.

### Remaining
- ✅ `examples/fetch` — shipped, with its Lisp veneer and a hermetic
  loopback test server. An adversarial review (3 lenses, per-finding
  verification) produced **18 findings, all 18 confirmed**, most reproduced
  empirically; every one is fixed and covered by a regression test. The
  sharpest were: a failed `download` reported as success (the sink drain
  loop could exit without ever re-entering the read that carries the
  error), an uncapped default body size that would exhaust the Lisp heap,
  CRLF request-splitting through caller-supplied header values, an
  audit-gate regex that could never fire because glibc imports are
  version-tagged, and a `TaskGuard` ordering that published "done" before
  releasing the admission permit.
- ✅ **Windows works** — and earlier than planned. `uintptr` is derived
  from the pointer size (naming a C type was wrong on LLP64, where
  `unsigned long` is 32 bits); the loader is abstracted over
  `dlopen`/`dlsym` and `LoadLibrary`/`GetProcAddress`; artifact naming
  knows Windows drops the `lib` prefix and uses `.dll`; the unique-copy
  load policy, added for macOS dyld caching, also sidesteps the DLL-in-use
  lock. Three real portability bugs surfaced on the way, none of them
  Windows-only in principle: a Cargo.toml scraper that could not tolerate
  CR, the golden fixture broken by CRLF translation, and Lisp format
  strings whose `~` end-of-line continuation is not the tilde-newline
  directive once a CR sits between them (the tree is now pinned to LF).
  The CI job is **required**, at 177/177. (It runs three fewer assertions
  than Linux: `fx.target-check` guards a couple of them behind
  `#+(and x86-64 linux)`.)
- ✅ A worked Deploy recipe (docs/distribution.md), including the two things
  that bite silently: platform-named artifacts and quiescing foreign
  threads in a dump hook.
- **Quicklisp: deliberately deferred to 1.0.** Until then rulisp ships via
  Ultralisp (and crates.io for the Rust side) — a pre-1.0 API does not
  belong in a dist users treat as stable.

Explicitly **not** in v0.3: the push/doorbell layer (no `StoredCallback` in
the example — declaring one forces `compile-file` and a C toolchain on ECL
at binding-generation time), streaming uploads, cookie/redirect/proxy
configuration, zero-copy `:string`, constructor `&key`.


v0.1.0 shipped the frozen boundary (BOUNDARY.md, ABI 1) and the PyO3-style
developer experience. Everything below is **additive on the wire** — the
manifest's ignore-unknown-keys rule and the universal `dealloc(ptr, size,
align)` ABI were designed so these land without an ABI bump.

Items are grouped by theme; roughly priority-ordered within each. Demand
notes reference real cases hit while building the examples.

## v0.2

### 1. Type vocabulary: binary data and optionals

- ✅ `:bytes` — **shipped** (0.2 dev): `&[u8]` / `Vec<u8>` crossings, same
  `(ptr,len)` + dealloc convention strings use, no UTF-8 validation.
  Verified on SBCL + CCL; oracle/golden updated in lockstep.
- ✅ `(:option T)` — **shipped** (0.2 dev): `Option<scalar/&str/&[u8]>`
  params and `Option<scalar/String/Vec<u8>>` results as a (present, value)
  pair; Lisp NIL ↔ None. `Option<bool>` is rejected at compile time (nil
  cannot distinguish None from Some(false)). rx gained `first-match`.
- ✅ `(:vec T)` — **shipped** (0.2 dev): `&[scalar]` params / `Vec<scalar>`
  results as element-counted `(ptr,len)`, freed via
  `dealloc(ptr, len*size, align)`; Lisp side gets specialized arrays.

### 2. Stored and cross-thread callbacks

- ✅ **Shipped** (0.2 dev): `StoredCallback<A>` + `rulisp:callback` tokens
  — registered closures Rust may store, clone and invoke from any thread
  (foreign threads are adopted; verified on SBCL AND CCL). Fail-safe
  lifetime: a dead id warns and errors, never dangles. The wire is the
  `userdata` slot v1 reserved — ABI 1 unchanged. Demand case closed: wasm
  host functions (examples/wasm `on-notify` + guest.wat).
- ✅ Queue-polling: documented as a five-line user pattern in
  docs/usage.md — a dedicated helper adds nothing over it.

### 3. Constructor `&key` arguments

**Deferred with cause** (was: deferred from M3). Dogfooding overturned the
premise: `(rx:make-regex "[0-9]+")` reads strictly better than
`(rx:make-regex :pattern "[0-9]+")` — all real constructors so far take
0–2 obvious positional arguments. Revisit only when a multi-argument
constructor demand case appears, and then as an OPT-IN attribute
(`#[rulisp(constructor, keyargs)]`), not a blanket rule.

### 4. Distribution tooling

- ✅ `rulisp:load-blob-crate` + the `lib<name>-<os>-<arch>.<ext>` naming
  convention, and `.github/workflows/blobs.yml` building release blobs for
  Linux x86-64 and macOS arm64 (dispatch + release tags).
- Still open: a worked Deploy integration example; official Quicklisp
  submission (rulisp builds without cargo — eligible).

### 5. Portability

- ✅ **ECL callback segfault — root-caused and fixed** (0.2 dev): an
  apparently unreported ECL bug (`si:make-dynamic-callback` doesn't
  GC-protect its libffi closure metadata — writeup for upstream filing in
  docs/upstream/ecl-dynamic-callback-gc.md). rulisp natively compiles
  trampolines on ECL instead of eval'ing them; full suite now green on
  ECL 21.2.1 (139/139), with one documented platform limitation:
  foreign-thread stored-callback invocation (ECL cannot adopt foreign
  threads).
- Image dump/restore on non-SBCL hosts (`ccl:save-application`, ECL);
  the m7 test currently passes vacuously off SBCL.
- Windows: excluded from v1; needs LLP64 `uintptr` handling, DLL
  file-locking discipline for reload, and CI.

### 6. Performance

- Zero-copy paths for `:bytes`/`:string` (static-vectors,
  `with-pointer-to-vector-data`) where the borrow contract allows.
- A small benchmark suite (call overhead, string sizes, callback round
  trips) so regressions are visible.

### 7. DX polish

- Opt-in `Display`-driven `print-object` for handles (DESIGN.md §6.4).
- ✅ Wasm linear-memory access via `:bytes` — shipped alongside `:bytes`
  (bounds-checked `memory-read`/`memory-write` + a guest function summing
  a host-written buffer). Still pending: host functions via stored
  callbacks, possibly WASI.

## Later / exploratory

- Tagged enums / richer value types (UniFFI-style semantics without the
  per-call serialization cost).
- Multiple return values mapped to CL `(values ...)`.
- Bulk zero-copy data via Apache Arrow's C data interface.
- LispWorks / Allegro / ABCL validation.

## Non-goals (unchanged from v0.1)

Auto-binding arbitrary existing crates; `&mut self` across the boundary;
`dlclose`/true unloading; Rust holding Lisp object references. See
DESIGN.md §1.

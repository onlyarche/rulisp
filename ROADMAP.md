# Roadmap

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
5. **`#[rulisp(constructor, name = "…")]`** — now load-bearing: since
   duplicate `:lisp-name` became a hard error, a two-constructor handle
   type is inexpressible without it. Scheduled for v0.4 by the v0.3 plan.
6. **Reusable signal-audit tool** — extract fetch's audit.sh into
   `tools/rulisp-audit.sh`, run it over all examples in CI, with a
   deliberately-failing fixture so the gate can never go inert again.
7. **docs/benchmarks.md** — the 24×/307× numbers get a documented,
   dated, release-profile method (`make bench` already builds release).
8. **ECL CI promotion to required** — gated on item 4 plus a green
   streak; "fully supported" and "may fail" cannot both be true.

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

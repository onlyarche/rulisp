# Roadmap

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
- `(:option T)` — `Option<T>` as (present, value) instead of sentinel
  values (`rx` currently has no clean "no match" story).
- `(:vec T)` for scalar element types.

### 2. Stored and cross-thread callbacks

v1 callbacks are borrowed, same-thread, call-duration only. The ABI already
reserves a `userdata` slot for registered callbacks.

- Stored callbacks: register a Lisp closure, invoke later.
  *Demand:* wasm host functions (guest code calling back into Lisp) —
  the single most-requested capability the wasm example surfaced.
- Cross-thread delivery: SBCL's foreign-thread callback adoption is
  source-verified; expose it deliberately, plus a queue-polling helper as
  the recommended high-frequency pattern (tokio/async bridges, event
  streams).

### 3. Constructor `&key` arguments

Deferred from M3 (DESIGN.md §11.6d): a manifest extension carrying
parameter defaults/keyword-ness plus CL codegen for `&key` lambda lists.

### 4. Distribution tooling

docs/distribution.md describes the patterns; v0.2 automates them:

- CI recipe + loader helper for committed per-platform blobs
  (`libfoo-<os>-<arch>.<ext>`, Shirakumo pattern) so end users need no
  Rust toolchain.
- A worked Deploy integration example for shipped executables.
- Official Quicklisp submission (rulisp builds without cargo — eligible).

### 5. Portability

- **ECL callback segfault** — the best-effort CI job is honestly red at
  the callback tests; investigate ECL's libffi closure path.
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

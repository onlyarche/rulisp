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

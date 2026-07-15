# rulisp Boundary Contract (ABI 1)

This is the normative contract between a rulisp glue cdylib (Rust side) and
the rulisp loader (Common Lisp side). The `#[rulisp::export]` /
`#[rulisp::handle]` / `rulisp::module!` macros generate exactly this;
`tests/m1-handwritten/` is the permanent hand-written reference
implementation ("ABI oracle") and `tests/golden/` pins the manifest bytes.

Breaking anything in this document is an ABI break: bump `abi_version()`
(exact-match required by the loader). Adding manifest keys is NOT a break —
unknown keys are ignored.

## 1. Symbols and per-library resolution

- Every export is prefixed `<crate>_rulisp_` (crate name with `-` → `_`).
- Each cdylib statically links its own copy of `rulisp-runtime`: last-error
  TLS and allocator pairing are **per library**. The loader therefore
  resolves every symbol against the specific `dlopen` handle, never the
  global namespace — after a reload, two generations export identical names.
- Library-level entry points:
  - `uint32_t <p>abi_version(void)` — checked first; `1`.
  - `const uint8_t *<p>manifest(uintptr_t *len)` — static UTF-8
    s-expression manifest; permanent borrow, never freed by the caller.
  - `void <p>last_error(const uint8_t **type_ptr, uintptr_t *type_len,
    const uint8_t **msg_ptr, uintptr_t *msg_len)` — see §3.
  - `void <p>dealloc(uint8_t *ptr, uintptr_t size, uintptr_t align)` — see §4.

## 2. Status codes

Every function shim returns `int32_t`; out-params are written only on `OK`.

| code | name | meaning | CL reaction |
|---|---|---|---|
| 0 | OK | success, out-params valid | convert and return |
| 1 | ERR | Rust returned `Err` | signal typed condition (⊂ `rulisp:rust-error`) |
| 2 | PANIC | panic caught in the shim | signal `rulisp:rust-panic` |
| 3 | INVALID | boundary rejected an argument (e.g. bad UTF-8) | signal `rulisp:invalid-argument` |
| 4 | CB_ERR | a Lisp callback signaled; condition stashed CL-side | re-signal the original condition |

Exception: `*_free` shims return `void`; a panic inside free is caught,
logged to stderr and swallowed (finalizer context has no error channel).

## 3. last_error

- Thread-local, per library. Valid (borrowed) until the next call into the
  same library on the same thread; the CL wrapper copies both strings
  immediately after reading a non-zero status.
- `type` is the Rust error type name (e.g. `"ParseError"`, `"Error"`,
  `"panic"`, `"InvalidUtf8"`); `msg` is the `Display` output (for panics:
  the payload if it is `&str`/`String`, else `"panic (non-string payload)"`).

## 4. Strings and buffers

- Wire format both directions: `(const uint8_t *ptr, uintptr_t len)`,
  UTF-8, **no NUL terminator, interior NULs legal**.
- Lisp→Rust: borrowed for the duration of the call. Rust validates UTF-8
  (failure → status 3). Rust must not retain the pointer (the macro only
  hands user code `&str`, making retention a compile error).
- Rust→Lisp: out-params `(uint8_t **ptr, uintptr_t *len)`. Ownership
  transfers to Lisp, which copies then releases **exactly once** via the
  owning library's `dealloc(ptr, len, 1)` (strings have align 1;
  `len == capacity` guaranteed by construction).
- Empty transfer: `len == 0` carries no allocation — the pointer is
  dangling, must not be dereferenced, and `dealloc` is skipped (a size-0
  dealloc is a no-op).
- Never `libc free()`; never another library's dealloc. Buffers returned by
  a generation-N call are released through generation N's dealloc (the CL
  wrapper's immutable generation context guarantees this even across
  concurrent reloads).

## 5. Handles

- A handle is `void*` = `Box::into_raw(Box<T>)`; constructors return it via
  `void **out`. Method shims reborrow `const void*` → `&T`. There is no
  `&mut` across the boundary and no by-value consumption.
- `T: Send + Sync + 'static` is enforced at compile time (supertrait bounds
  of `HandleType`): finalizers may drop on any thread (`Send`) and
  concurrent `&self` calls on one handle are allowed (`Sync`).
- Free: `void <p>_<type>_free(void*)`, NULL is a no-op. **A non-NULL double
  free is undefined behavior at the C level**; exactly-once is guaranteed
  by the CL handle cell state machine (in-flight counting + deferred free:
  a free racing an in-flight call is accepted, deferred, and executed by
  the last call to finish).
- Generation discipline: a handle is stamped with the generation of the
  wrapper that created it and is only accepted by wrappers of that same
  birth generation; it is always freed by its birth generation's free shim.

## 6. Callbacks

Wire: one function-pointer parameter (per-signature typedef, first param
`uint64_t userdata`, then the encoded arguments) plus a reserved
`uint64_t userdata` (0 in v1). The trampoline returns `0` (OK) or `1`
(a condition was signaled and stashed CL-side).

Contract:
1. A callback may be invoked only on the calling thread, before the export
   returns. Enforced in Rust: `Callback<'a, A, ()>` is `!Send`/`!Sync` and
   lifetime-pinned to the shim frame — storing or moving it is a compile
   error.
2. A Lisp condition never unwinds Lisp-style through Rust frames: the
   trampoline catches `serious-condition`, stashes it, returns 1. Rust sees
   `Err(CallbackError)` and unwinds normally (destructors run). Propagated
   with `?`, the shim reports status 4 and the CL wrapper re-signals the
   original condition object.
3. If Rust swallows the `CallbackError` and returns `Ok`, the stash is
   discarded (its dynamic binding scope ends). If Rust swallows it and then
   fails with its own error while a callback had signaled during the same
   shim call, the call is conservatively classified as status 4 and the
   stashed condition is re-signaled.
4. **Documented UB**: a non-local Lisp exit (`throw`, `return-from`, a
   restart transfer) out of a callback unwinds through live Rust frames,
   skipping destructors. This cannot be prevented from Lisp; the trampoline
   logs a best-effort warning. Signal conditions instead — they are caught
   and tunneled correctly.

## 7. Threads and signals

- Any Lisp thread may call any export; execution is on the calling thread.
  No global lock, no runtime.
- Concurrent method calls on one handle are allowed (`T: Sync` carries the
  load). Free-vs-in-flight races are resolved by deferral (§5).
- Rust code may spawn internal threads but cannot call Lisp callbacks from
  them (`!Send`, §6.1).
- Signals: a plain Rust cdylib (tokio included) installs no signal
  handlers. **Audit glue-crate dependencies for `sigaction`** (JIT,
  wasmtime, crash-handler crates are the usual offenders) — SBCL's GC is
  signal-driven and foreign handlers are a stability hazard. The Lisp side
  owns SIGINT/SIGTERM; expose an explicit Rust shutdown function instead of
  trapping signals.

## 8. Panics and non-local exits

- Every shim body runs under `catch_unwind`; a panic maps to status 2.
- `panic = "abort"` builds are rejected at compile time
  (`compile_error!` in rulisp-runtime): with abort, the first panic would
  kill the host image.
- Shims are `extern "C"` (not `"C-unwind"`): an escaped panic — which the
  wrapper makes impossible — would abort rather than corrupt the caller.
- Poisoned mutexes after a caught panic are the glue crate's own concern
  (subsequent `.lock().unwrap()` panics are themselves caught and reported
  as status 2).

## 9. Reload and unloading

- The loader never calls `dlclose`. Old generations stay mapped forever
  (one leaked mapping per reload; zero in production). This is what makes
  TLS destructors, `std::thread`, and stale-generation frees safe.
- Every load dlopens a **unique copy** of the artifact, defeating dlopen
  path caching (macOS dyld would otherwise silently return the old
  mapping). Older cache copies are unlinked (mappings keep the inodes
  alive).

## 10. Image dump / restore

- On restore, the loader first bumps a global session counter — every
  pre-dump handle cell and captured wrapper closure is instantly invalid
  (signaling, never dereferencing) — then reloads each crate from its
  recorded artifact path and regenerates all bindings.
- Freeing a dead-session handle performs no foreign call (the pointer
  belonged to a previous process image).

## 11. Manifest

- UTF-8 s-expression, grammar: keywords, strings, integers, lists, `nil`.
  Read hardened: `*read-eval*` nil, scratch package, closed grammar.
- `:schema` (form version, accept `<=` supported), `:abi` (must equal
  `abi_version()` exactly), `:crate`, `:crate-version`, `:target` (checked
  against the host, unknown tokens pass), `:prefix`, `:errors` (Rust error
  type names that become condition classes), `:handles`, `:functions`.
- Unknown keys are ignored everywhere: additive evolution is free.
- v1 type vocabulary (closed): `:unit :bool :i8 :i16 :i32 :i64 :u8 :u16
  :u32 :u64 :f32 :f64 :string (:handle "Name")
  (:callback :params (...) :result :unit)`.

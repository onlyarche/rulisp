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
  (failure → status 3). Rust must not retain the pointer. Retention is a
  compile error, enforced twice (issue #1 showed one layer is not enough:
  an explicit `&'static str` in an export signature used to defeat it from
  safe Rust): the macro rejects any explicit lifetime in an export
  signature, and every borrowing helper takes a per-call `ShimFrame` whose
  borrow pins the returned lifetime to the shim invocation — so even code
  that bypasses the macro check cannot name a longer lifetime and have it
  unify. The same two layers cover byte buffers, scalar slices, handle
  references and borrowed callbacks.
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

Stored callbacks (0.2, `StoredCallback<A>`): same wire, different
trampoline — the leading `uint64` carries a registry id minted by
`rulisp:callback`, whose CALLBACK-TOKEN keeps the closure registered.
Differences from the borrowed form:

- Storable, `Clone`/`Copy`, `Send + Sync`: Rust may keep it and invoke
  from any thread (the Lisp adopts foreign threads on entry; verified on
  SBCL and CCL).
- Lifetime is fail-safe, not compile-enforced: once the token is
  unregistered (explicitly or by GC), invocation returns an error status
  after a Lisp-side warning — a dead id can never dangle.
- Error protocol: there may be no rulisp call frame on the invoking
  thread, so a signaled condition is WARNED and reported as
  `Err(CallbackError)` (status 1; a dead id is status 2). No stash, no
  re-signal, no status 4.
- The non-local-exit clause above applies identically.

## 7. Threads and signals

- Any Lisp thread may call any export; execution is on the calling thread.
  No global lock, no runtime.
- Concurrent method calls on one handle are allowed (`T: Sync` carries the
  load). Free-vs-in-flight races are resolved by deferral (§5).
- Rust code may spawn internal threads but cannot call Lisp callbacks from
  them (`!Send`, §6.1).
- **Blocking exports must cap their wait in Rust, and the loop belongs in
  Lisp.** A Lisp thread inside a foreign call cannot be interrupted — SBCL
  cannot deliver `sb-thread:interrupt-thread` there — so an export that
  waits without a bound makes the image unkillable. Take a `wait_ms`
  parameter, cap it (100 ms is a good default), return a "not ready yet"
  answer, and let the caller loop in Lisp where interrupts and restarts
  work.
- **A blocking export must refuse re-entry from its own runtime's worker
  thread** (e.g. `Handle::try_current().is_some()`) and report it as an
  error, rather than letting the async runtime panic inside `catch_unwind`.
- ECL specifics: callback trampolines are natively compiled at load time
  (a C toolchain must be present — bytecodes defcallbacks are unsafe on
  ECL, see docs/upstream/ecl-dynamic-callback-gc.md), and foreign-thread
  invocation of stored callbacks is UNSUPPORTED there: ECL cannot adopt
  threads it didn't create (`ecl_import_current_thread` would have to run
  on the foreign thread itself). Invoke stored callbacks from Lisp-visible
  threads only, or use the queue pattern.
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
- **There is no guardrail against dumping with live foreign threads.**
  `save-lisp-and-die` refuses to run with multiple *Lisp* threads, but it
  does not see threads a glue crate spawned — the dump succeeds and those
  threads simply do not exist in the restored image, while any state they
  owned is gone. A crate that owns threads (an async runtime, a watcher)
  must export an explicit shutdown entry point.
- **Declared dump hooks** (`:on-dump`, wire-additive since 0.4): a crate
  may name ONE of its own exports in the manifest key
  `(:on-dump "symbol")`. The named function must be declared in
  `:functions` with zero parameters and `:unit` result (`:error` may name
  a type); the loader refuses the manifest otherwise. The loader
  registers a single image-dump hook that, immediately before a dump,
  calls every loaded crate's declared hook **in load order**. A non-OK
  status (error or panic) is reported as a warning and the dump proceeds
  — a dump must never be wedged by its own cleanup. Hook bodies are
  subject to §7's capped-wait rule as a normative requirement: an
  unbounded wait here makes the image undumpable. The hook is
  **dump-only**: reload does not call it (stale-generation state is
  already recoverable through §9), and the restored image never re-runs
  it. Crates without the key keep the manual pattern: export a shutdown
  function and have the application register the hook itself.

## 11. Manifest

- UTF-8 s-expression, grammar: keywords, strings, integers, lists, `nil`.
  Read hardened: `*read-eval*` nil, scratch package, closed grammar.
- `:schema` (form version, accept `<=` supported), `:abi` (must equal
  `abi_version()` exactly), `:crate`, `:crate-version`, `:target` (checked
  against the host, unknown tokens pass), `:prefix`, `:errors` (Rust error
  type names that become condition classes), `:handles`, `:functions`.
- Unknown keys are ignored everywhere: additive evolution is free.
- Type vocabulary (closed): `:unit :bool :i8 :i16 :i32 :i64 :u8 :u16
  :u32 :u64 :f32 :f64 :string :bytes (:option T) (:vec S)
  (:handle "Name") (:callback :params (...) :result :unit)
  (:stored-callback :params (...) :result :unit)`.
  - `(:option T)`, T ∈ scalars/`:string`/`:bytes` (0.2): a leading
    `uint8` present flag; the value's usual wire representation follows and
    is meaningful only when present. Lisp NIL ↔ None. `:bool` inner is
    rejected (nil ambiguity).
  - `(:vec S)`, S a scalar (0.2): `(const S*, uintptr_t len)` counted in
    ELEMENTS; owned returns are freed via
    `dealloc(ptr, len * sizeof(S), alignof(S))`.
  `:bytes` (added in 0.2, wire-additive on ABI 1) uses the exact `:string`
  convention — borrowed `(ptr,len)` in, owned + dealloc'd out, empty
  transfer at len 0 — minus UTF-8 validation; Rust sees `&[u8]` in and
  returns `Vec<u8>`.

## 12. Conformance: claim → enforcement

Issue #1 was a documented claim that turned out to be enforced by nothing.
This table is the standing answer to "which of these sentences are backed
by what": every normative claim in §1–§11, classified. Rebuild it whenever
a section changes. (v0.4 plan item 1; produced by an exhaustive sweep with
per-citation verification.)

Legend: **compile-error** = macro check or type-system mechanism · **runtime-check** = code on the load/call path · **test** = a suite/trybuild/shell gate that fails when the claim breaks · **UB-by-design** = documented, deliberately unenforced · **GAP** = documented, enforced by nothing found.

| Claim | Enforcement | Where |
|---|---|---|
| **§1 preamble — ABI discipline** | | |
| Breaking the contract requires bumping `abi_version()`; loader requires exact match | runtime-check | `lisp/src/crate.lisp:147-149` (`abi-mismatch-error` unless `= +abi-version+`) |
| Adding manifest keys is NOT a break — unknown keys are ignored | test | `fx.unknown-keys-ignored` (`tests/suite/m2.lisp:57-61`) |
| `tests/golden/` pins the manifest bytes (macro output byte-identical) | test | `fx.golden-manifest` (`tests/suite/m2.lisp:125-138`) |
| **§1 — Symbols and per-library resolution** | | |
| Every export is prefixed `<crate>_rulisp_` (crate `-` → `_`) | runtime-check | `lisp/src/crate.lisp:180-185` (`manifest-error` if prefixed symbol absent); prefix minted `crates/rulisp-macros/src/lib.rs:22-28` |
| Loader resolves every symbol against the specific dlopen handle, never the global namespace | runtime-check | `lisp/src/ffi.lisp:77-80` (`dlsym-ptr`); `%find-symbol-in` `ffi.lisp:43-44` |
| After a reload two generations export identical names yet stay distinct per wrapper/handle | test | `m6.reload` + `m6.captured-wrapper-gate` (`tests/suite/m1.lisp:234,248`) |
| Each cdylib statically links its own rulisp-runtime copy: last-error TLS and allocator pairing per library | test | `v04.last-error-is-per-library` (`tests/suite/v04.lisp`): concurrent failures in wordbag and rx never cross |
| `abi_version()` is checked first, before the manifest is read; must equal 1 | runtime-check | `lisp/src/crate.lisp:140-149` (`%open-and-verify`) |
| `manifest()` is a static permanent borrow (`'static str` behind OnceLock/static) | compile-error | `crates/rulisp-macros/src/lib.rs:1184-1208`; oracle `tests/m1-handwritten/src/lib.rs:17,37-42` |
| Caller copies the manifest and never frees it | runtime-check | `lisp/src/crate.lisp:163-172` (`%read-library-manifest`: copies, no dealloc) |
| `last_error` and `dealloc` entry points exist per library (resolved at load) | runtime-check | `lisp/src/crate.lisp:186-187` (resolve signals `manifest-error` if missing) |
| **§2 — Status codes** | | |
| Every function shim returns `int32_t` | compile-error | `crates/rulisp-macros/src/lib.rs:719-729` (generated shim signature `-> i32`) |
| Out-params are written only on OK | test | `v04.out-params-untouched-on-err` (`tests/suite/v04.lisp:117-147`) |
| OK (0): out-params valid; CL converts and returns | test | `m3.strings` (`tests/suite/m1.lisp:102`); dispatch `lisp/src/codegen.lisp:448-451` |
| ERR (1): Rust `Err` → typed condition ⊂ `rulisp:rust-error` | test | `m3.typed-conditions` (`tests/suite/m3.lisp:11`); `m2.fallible` (`tests/suite/m1.lisp:87`) |
| PANIC (2): panic caught in shim → `rulisp:rust-panic`, image survives | test | `m1.panic` (`tests/suite/m1.lisp:57-63`) |
| INVALID (3): boundary rejects a bad argument (e.g. bad UTF-8) as status 3 | runtime-check | `crates/rulisp-runtime/src/lib.rs:148-162` (`str_arg`); no e2e test drives Rust-side status 3 |
| Status 3 → CL signals `rulisp:invalid-argument` | runtime-check | `lisp/src/codegen.lisp:492-496` |
| CB_ERR (4): CL re-signals the original stashed condition object | test | `m5.callback-condition-identity` (`tests/suite/m1.lisp:191-204`) |
| Exception: `*_free` returns void; a panic inside free is caught, logged to stderr, swallowed | test | `v04.free-shim-swallows-drop-panic` (`tests/suite/v04.lisp:53-67`); shim `crates/rulisp-macros/src/lib.rs:864-872` |
| **§3 — last_error** | | |
| `last_error` is thread-local | test | `v04.last-error-is-thread-local` (`tests/suite/v04.lisp:96-110`) |
| `last_error` is per library (each cdylib its own TLS slot; errors never cross libraries) | test | `v04.last-error-is-per-library` (`tests/suite/v04.lisp`) |
| CL reads `last_error` through the owning generation's resolved pointer | runtime-check | `lisp/src/codegen.lisp:479-496` (`gen-ctx-last-error-ptr`); resolved `lisp/src/crate.lisp:186` |
| Borrowed until next call into same library on same thread; CL copies both strings immediately | runtime-check | `lisp/src/ffi.lisp:221-232` (`read-crate-last-error` copies; called from `codegen.lisp:479-494`) |
| `type` is the Rust error type name; `msg` is the Display output | test | `m2.fallible` (`tests/suite/m1.lisp:94-96`: `"ParseError"` + exact Display text) |
| Panics: type `"panic"`, msg is the payload when `&str`/`String` | test | `m1.panic` (`tests/suite/m1.lisp:57-62`); `crates/rulisp-runtime/src/lib.rs:105-120` |
| Non-string panic payload → msg `"panic (non-string payload)"` | runtime-check | `crates/rulisp-runtime/src/lib.rs:109-116` (branch untested) |
| UTF-8 rejection records type `"InvalidUtf8"` | runtime-check | `crates/rulisp-runtime/src/lib.rs:159` |
| **§4 — Strings and buffers** | | |
| Wire format both directions: `(ptr,len)` UTF-8 | test | `m3.strings` (`tests/suite/m1.lisp:102-108`) |
| No NUL terminator; interior NULs legal | runtime-check | `lisp/src/ffi.lisp:178-181` (length-delimited encode); `crates/rulisp-runtime/src/lib.rs:148-162`; no interior-NUL test |
| Lisp→Rust: borrowed for the duration of the call (dynamic-extent pin/copy) | runtime-check | `lisp/src/ffi.lisp:152-181` (`call-with-bytes-arg` / `call-with-utf8-arg`) |
| Rust validates UTF-8; failure → status 3 | runtime-check | `crates/rulisp-runtime/src/lib.rs:148-162` (`str_arg`) |
| Retention layer 1: macro rejects any explicit lifetime in an export signature | compile-error | `crates/rulisp-macros/src/lib.rs:97-138,909-917`; pinned by `crates/rulisp/tests/ui/static_lifetime.rs` (trybuild) |
| Retention layer 2: borrowing helpers pin the returned lifetime to a per-call ShimFrame | compile-error | `crates/rulisp-runtime/src/lib.rs:130-162` (`ShimFrame` + `str_arg<'a>(&'a ShimFrame)`) |
| Both layers cover byte buffers, scalar slices, handle references and borrowed callbacks | compile-error | `crates/rulisp-runtime/src/lib.rs:202-255`; `crates/rulisp/src/lib.rs:167-177`; `ui/static_lifetime.rs:22-56` |
| Rust→Lisp: Lisp copies then releases exactly once via the owning library's `dealloc(ptr,len,1)` | test | `m3.string-allocations` (`tests/suite/m1.lisp:110-117`); `v02.bytes-alloc-pairing` (`tests/suite/v02.lisp:33-39`) |
| Strings have align 1; `len == capacity` guaranteed by construction | runtime-check | `crates/rulisp-runtime/src/lib.rs:168-181` (`into_boxed_slice`); align-1 dealloc `lisp/src/ffi.lisp:243-245` |
| Empty transfer: len 0 carries no allocation and dealloc is skipped | test | `v02.bytes-roundtrip` + `v02.bytes-alloc-pairing` (`tests/suite/v02.lisp:20,33`); `m3.strings` ECHO `""` |
| len-0 dangling pointer never dereferenced; size-0 dealloc is a no-op | runtime-check | `lisp/src/ffi.lisp:134-150,234-241`; `crates/rulisp-runtime/src/lib.rs:231-234` |
| Never libc free/another library's dealloc; gen-N buffers freed via gen N's dealloc across reloads | runtime-check | `lisp/src/codegen.lisp:13-21,286-298` (immutable gen-ctx captures dealloc-ptr); no concurrent-reload test |
| **§5 — Handles** | | |
| Handle is `void*` = `Box::into_raw(Box<T>)`; constructors return it via `void **out` | runtime-check | `crates/rulisp-runtime/src/lib.rs:243-245` (`handle_new`); `crates/rulisp-macros/src/lib.rs:623-626` (`out: *mut *mut c_void`) |
| Method shims reborrow `const void*` → `&T` | runtime-check | `crates/rulisp-runtime/src/lib.rs:253-255` (`handle_ref`); `crates/rulisp-macros/src/lib.rs:535-544` |
| No `&mut` across the boundary and no by-value consumption | compile-error | `crates/rulisp-macros/src/lib.rs:144-150` (&mut param), `919-937` (&mut/by-value self); `tests/ui/mut_self.rs` |
| `T: Send + Sync + 'static` enforced at compile time (HandleType supertrait bounds) | compile-error | `crates/rulisp/src/lib.rs:58`; impl emitted at `crates/rulisp-macros/src/lib.rs:846-852`; `tests/ui/non_send_handle.rs` |
| Free shim: NULL is a no-op | runtime-check | `crates/rulisp-runtime/src/lib.rs:261-265` (`handle_free` null check) |
| A non-NULL double free is undefined behavior at the C level | UB-by-design | `BOUNDARY.md:86-88`; safety contract `crates/rulisp-runtime/src/lib.rs:257-260` |
| Exactly-once free via CL cell state machine; free racing in-flight call accepted, deferred, run by last call | runtime-check | `lisp/src/handle.lisp:54-97` (`cell-end-call`, `%cell-free`); tests `m4.handle-lifecycle`, `m4.free-vs-in-flight` (`tests/suite/m1.lisp:124-163`) |
| Handle stamped with birth generation; accepted only by wrappers of that same birth generation | runtime-check | `lisp/src/handle.lisp:30-52` (`cell-begin-call` gate); `lisp/src/codegen.lisp:400-406,316-326`; test `m6.captured-wrapper-gate` |
| Handle always freed by its birth generation's free shim | runtime-check | `lisp/src/codegen.lisp:316-326` (gen-ctx free-table); `lisp/src/handle.lisp:65,91` (`cell-free-fn`); test `m6.reload` (`tests/suite/m1.lisp:243`) |
| **§6 — Callbacks (wire + borrowed)** | | |
| Fn-ptr param + reserved uint64 userdata (0 in v1); trampoline returns 0 OK / 1 condition-stashed | runtime-check | `lisp/src/codegen.lisp:111-139` (returns), `:420` (`:uint64 0`); `crates/rulisp-macros/src/lib.rs:546-559` |
| §6.1 Callback invoked only on calling thread before export returns; `!Send`/`!Sync` + lifetime-pinned; storing = compile error | compile-error | `crates/rulisp/src/lib.rs:115-119` (`PhantomData *mut ()`), `162-177` (ShimFrame pin); `tests/ui/stored_callback.rs`, `tests/ui/static_lifetime.rs` |
| §6.2 Lisp condition never unwinds through Rust: trampoline catches serious-condition, stashes it, returns 1 | runtime-check | `lisp/src/codegen.lisp:119-133`; test `m5.callback-condition-identity` |
| §6.2 Rust sees `Err(CallbackError)` and unwinds normally: destructors run | test | `m5.callback-condition-identity` (`tests/suite/m1.lisp:191-204`, guard-drops assertion `:203`); Err mapping `crates/rulisp/src/lib.rs:182-190` |
| §6.2 Propagated with `?`: shim reports status 4; CL wrapper re-signals the original condition object | runtime-check | `crates/rulisp-macros/src/lib.rs:683-716` (CB tunnel); `lisp/src/codegen.lisp:497-501`; identity tested by `m5.callback-condition-identity`, `m4h.nested-callbacks` |
| §6.3 Rust swallows CallbackError and returns Ok: stash discarded (dynamic binding scope ends) | test | `v04.swallowed-callback-error-is-discarded` (`tests/suite/v04.lisp:14-26`); binding `lisp/src/codegen.lisp:414-417` |
| §6.3 Swallow-then-fail with a stashed condition is conservatively status 4; original condition re-signaled | runtime-check | `crates/rulisp-macros/src/lib.rs:704-716` (tunnel_check on Err branch); test `v04.swallow-then-fail-resignals-the-original` (`tests/suite/v04.lisp:35-46`) |
| §6.4 Non-local Lisp exit unwinds through Rust frames skipping destructors; trampoline logs best-effort warning | UB-by-design | `BOUNDARY.md:117-121`; warning at `lisp/src/codegen.lisp:134-139` |
| **§6 — Stored callbacks** | | |
| Same wire, different trampoline; leading uint64 carries registry id minted by `rulisp:callback`; token keeps closure registered | runtime-check | `lisp/src/stored-callback.lisp:37-53`; `lisp/src/codegen.lisp:421-435` (token-id in `:uint64` slot) |
| Storable, Clone/Copy, Send+Sync; Rust may invoke from any thread (Lisp adopts foreign threads; SBCL/CCL) | test | `v02.stored-callback-cross-thread` (`tests/suite/v02.lisp:118-137`); derives `crates/rulisp/src/lib.rs:132-137` |
| Unregistered/GC'd token: invocation returns error status after Lisp-side warning; dead id never dangles | runtime-check | `lisp/src/codegen.lisp:179-185` (lookup nil → warn, status 2); test `v02.stored-callback-dead-id` (`tests/suite/v02.lisp:139-152`) |
| Signaled condition is warned, reported `Err(CallbackError)` status 1 (dead id 2); no stash, no re-signal, no status 4 | runtime-check | `lisp/src/codegen.lisp:194-197`; no tunnel in `crates/rulisp/src/lib.rs:151-159`; test `v02.stored-callback-condition` (`v02.lisp:154-170`) |
| Non-local-exit UB clause applies identically to stored callbacks | UB-by-design | `BOUNDARY.md:138`; warning at `lisp/src/codegen.lisp:198-200` |
| **§7 — Threads and signals** | | |
| Any Lisp thread may call any export; execution on the calling thread; no global lock, no runtime | test | `m4h.thread-race` (`tests/suite/m4.lisp:18-53`); also `fetch.concurrent-lisp-threads` (`tests/suite/fetch.lisp:254`) |
| Concurrent method calls on one handle allowed (`T: Sync` carries the load) | compile-error | `crates/rulisp/src/lib.rs:58` (Sync supertrait); `tests/ui/non_send_handle.rs`; exercised by `m4h.thread-race` |
| Free-vs-in-flight races resolved by deferral (restates §5) | test | `m4.free-vs-in-flight` (`tests/suite/m1.lisp:151-163`); mechanism `lisp/src/handle.lisp:54-97` |
| Rust internal threads cannot call borrowed Lisp callbacks (`!Send`) | compile-error | `crates/rulisp/src/lib.rs:115-118` (`PhantomData *mut ()`); `tests/ui/stored_callback.rs` |
| Blocking exports must cap their wait in Rust; the loop belongs in Lisp (glue-author norm) | test | `fetch.waits-are-capped` (`tests/suite/fetch.lisp:62-75`); cap `examples/fetch/src/lib.rs:42-47` — reference crate only, unenforceable for third-party glue |
| Blocking export must refuse re-entry from its own runtime's worker thread, reported as an error | runtime-check | `examples/fetch/src/lib.rs:52-59` (`refuse_reentry`; call sites 322,338,603,641) — reference crate only; no test can trigger it from Lisp |
| ECL: callback trampolines natively compiled at load time; missing C toolchain fails via named `manifest-error` | runtime-check | `lisp/src/codegen.lisp:87-103` (`#+ecl` compile-file branch); test `v04.ecl-toolchain-failure-is-named` (`tests/suite/v04.lisp:156-166`, non-vacuous on ECL only) |
| ECL: foreign-thread invocation of stored callbacks UNSUPPORTED (cannot adopt foreign threads) | UB-by-design | `BOUNDARY.md:158-164`; `docs/upstream/ecl-dynamic-callback-gc.md`; `#+ecl` skip `tests/suite/v02.lisp:118-124` |
| Plain Rust cdylib installs no signal handlers; audit glue-crate deps for sigaction | test | `examples/fetch/audit.sh:18-23` (`nm -D` signal-symbol sweep + tokio feature check, run by `Makefile:24`) — shell gate, fetch-only; v0.4 plan item 6 generalizes it |
| Lisp side owns SIGINT/SIGTERM; expose an explicit Rust shutdown function instead of trapping signals | **GAP** (scheduled: v0.4 item 6) | fetch demonstrates the pattern (`Client::shutdown` `examples/fetch/src/lib.rs:337`; audit.sh bans signal symbols) but nothing enforces the norm generally |
| **§8 — Panics and non-local exits** | | |
| Every shim body runs under `catch_unwind`; a panic maps to status 2 | runtime-check | `crates/rulisp-runtime/src/lib.rs:105-120` (`rt::shim`); every generated shim wrapped `crates/rulisp-macros/src/lib.rs:719-729`; test `m1.panic` |
| `panic = "abort"` builds are rejected at compile time (`compile_error!` in rulisp-runtime) | compile-error | `crates/rulisp-runtime/src/lib.rs:11-17`; proven non-vacuous by `m1.panic-abort-guard` (`tests/suite/m1.lisp:65-81`) |
| Shims are `extern "C"` not `"C-unwind"`: an escaped panic aborts rather than corrupting the caller | runtime-check | `crates/rulisp-macros/src/lib.rs:721,865,1198-1221` (all shims/entry points `extern "C"`; abort-on-escape is rustc's extern-C backstop) |
| Poisoned mutexes after a caught panic are the glue crate's own concern (rulisp adds no mitigation) | UB-by-design | `BOUNDARY.md:180-182` |
| Subsequent `.lock().unwrap()` on a poisoned mutex panics, is caught, reported as status 2 | test | `v04.poisoned-mutex-reports-panic` (`tests/suite/v04.lisp:74-89`; oracle `word_bag_poison` `tests/m1-handwritten/src/lib.rs:391-398`) |
| **§9 — Reload and unloading** | | |
| The loader never calls dlclose; old generations stay mapped forever | test | `m6.captured-wrapper-gate` (`tests/suite/m1.lisp:248-268`): old-gen wrapper+handle callable post-reload (`:262`); no dlclose/FreeLibrary anywhere in `lisp/src` |
| One leaked mapping per reload (zero in production) — a deliberate, accepted leak | UB-by-design | `BOUNDARY.md:185-188`; `lisp/src/crate.lisp:3-6` |
| Persisting mappings make TLS destructors, `std::thread`, and stale-generation frees safe | test | `m6.reload` (`tests/suite/m1.lisp:243`: stale handle freed via birth-gen shim); TLS-destructor half rides on no-dlclose, untested directly |
| Every load dlopens a unique copy of the artifact, defeating dlopen path caching | runtime-check | `lisp/src/crate.lisp:110-121` (counter+timestamp copy name, `uiop:copy-file`), `:140-141` (dlopen the copy) |
| Older cache copies are unlinked; live mappings keep the inodes alive | runtime-check | `lisp/src/crate.lisp:282-292` (`%sweep-crate-cache`), invoked at `:209` — no test exercises the sweep |
| **§10 — Image dump / restore** | | |
| On restore the loader bumps the global session counter FIRST, before any reload | runtime-check | `lisp/src/crate.lisp:306-311` (`incf *session*` precedes the reload loop; hook registered `:321`) |
| Every pre-dump handle cell is invalid: signals `stale-handle-error`, never dereferences | runtime-check | `lisp/src/handle.lisp:37-52` (session gate in `cell-begin-call`); pinned by `m7.dump-restore` (`tests/suite/m1.lisp:312-316`) |
| Every captured wrapper closure of a dead session refuses (`crate-not-loaded-error`) | runtime-check | `lisp/src/codegen.lisp:469-474`; pinned by `m7.dump-restore` (`tests/suite/m1.lisp:319-323`) |
| Then each crate reloads from its recorded artifact path and all bindings regenerate | test | `m7.dump-restore` (`tests/suite/m1.lisp:310-311`: post-restore GREET works); mechanism `lisp/src/crate.lisp:311-319` |
| Freeing a dead-session handle performs no foreign call | runtime-check | `lisp/src/handle.lisp:69-75` (`%maybe-foreign-free` session gate); m7 exercises explicit free + GC-finalizer path (`m1.lisp:317,324-329`) |
| No guardrail against dumping with live foreign threads; they vanish on restore, their state gone | UB-by-design | `BOUNDARY.md:202-209` |
| Thread-owning crates quiesce before a dump via the declared `:on-dump` hook (or the manual pattern) | runtime-check | `%run-crate-dump-hooks` + `%validate-on-dump`; tests `v04.on-dump-*`, `fetch.dump-hook-quiesces`, `fetch.dump-restore-refuses` | v0.4 plan item 3 (`#[rulisp(on_dump)]`) — not yet shipped (grep confirms `on_dump` exists only in `docs/design/v04-plan.md`) |
| **§11 — Manifest** | | |
| Manifest read hardened: `*read-eval*` nil, symbols land in a scratch package | runtime-check | `lisp/src/manifest.lisp:8-10,24-33`; test `fx.read-eval-blocked` (`tests/suite/m2.lisp:26-29`) |
| Grammar closed: keywords, strings, integers, lists, nil only — anything else rejected | runtime-check | `lisp/src/manifest.lisp:35-49` (`%sanitize`); test `fx.unknown-symbols-rejected` (`tests/suite/m2.lisp:31-33`) |
| `:schema` accepted only when <= supported form version (1) | runtime-check | `lisp/src/manifest.lisp:125-128`; test `fx.newer-schema-refused` (`tests/suite/m2.lisp:35-37`) |
| `:abi` must equal `abi_version()` exactly (loader exact-match + manifest/entry-point agreement) | runtime-check | `lisp/src/crate.lisp:147-153` — no suite test simulates a mismatch |
| `:target` checked against the host; unknown tokens pass | runtime-check | `lisp/src/manifest.lisp:103-118` + `lisp/src/crate.lisp:154-160`; test `fx.target-check` (`tests/suite/m2.lisp:71-78`) |
| Required keys and well-formed specs; any corruption signals a named `manifest-error` | runtime-check | `lisp/src/manifest.lisp:51-61,120-145`; tests `fx.missing-required-keys`, `fx.not-a-manifest`, `fx.bad-param-form` (`tests/suite/m2.lisp`) |
| `:errors` names become condition classes, subclasses of `rulisp:rust-error` | test | `m3.typed-conditions` (`tests/suite/m3.lisp:11-28`); mechanism `lisp/src/crate.lisp:191-193,267-269` |
| Unknown keys are ignored everywhere; additive evolution is free | test | `fx.unknown-keys-ignored` (`tests/suite/m2.lisp:57-61`); getf-based parsing ignores by construction |
| Type vocabulary is closed: tokens outside it signal `manifest-error` at binding generation | runtime-check | `lisp/src/codegen.lisp:40-42,63-69,141-149`; test `fx.partial-generation-ban` (`m2.lisp:96-118`); macro side: trybuild `ui/bad_type.rs` |
| `(:option T)`: leading uint8 present flag; value meaningful only when present; Lisp NIL ↔ None | test | `v02.option-result` + `v02.option-param` (`tests/suite/v02.lisp:52-62`); mechanism `codegen.lisp:248-269,360-379`, `ffi.lisp:183-193` |
| `(:option T)` with `:bool` inner is rejected (nil ambiguity) | compile-error | `crates/rulisp-macros/src/lib.rs:200-204` (param), `333-337` (result) |
| `(:option :bool)` rejected by the loader too (hand-written manifests) | runtime-check | `option-inner` (`lisp/src/codegen.lisp`), both param and result branches; test `v04.option-bool-rejected-by-the-loader` |
| `(:vec S)`: S scalar only; len counts ELEMENTS; freed via `dealloc(ptr, len*sizeof(S), alignof(S))` | runtime-check | `lisp/src/codegen.lisp:63-69,300-314`; `crates/rulisp-runtime/src/lib.rs:186-194`; test `v02.vec-roundtrip` (`v02.lisp:69-81`) |
| `:bytes` = exact `:string` convention minus UTF-8 validation; empty transfer at len 0 | test | `v02.bytes-in`/`bytes-roundtrip`/`bytes-alloc-pairing` (`tests/suite/v02.lisp:10-45`); no-validation path `crates/rulisp-runtime/src/lib.rs:210-222` |

## Verification notes

- Every `file:line` above was read and confirmed against the working tree. Two citations in the input were corrected: the oracle manifest static (`tests/m1-handwritten/src/lib.rs:17,37-42`, was 18,40-43) and the stored-callback dead-id branch (`codegen.lisp:179-185`, was 179-186).
- All five GAP rows were re-hunted: no enforcement found for any (grep for `on_dump`, cross-library tests, general signal audit, loader-side option-bool validation all came up empty).
- Test spot-checks (fail-if-broken confirmed): `fx.unknown-keys-ignored`, `m5.callback-condition-identity` (eq-identity assertion), `m4.free-vs-in-flight` (live-count timing assertions), `v02.bytes-alloc-pairing` (LIVE_ALLOCATIONS drift), `m7.dump-restore` (subprocess exit-code + RESTORE-OK), plus all seven new v0.4 tests.


# rulisp v0.3 — FINAL async plan: `examples/fetch`

*Lead architect's decision. Supersedes all three candidate designs. Grounded against HEAD (`39e0e66`) + working tree, verified 2026-08-03.*

---

## 0. REPO-STATE BLOCKER — resolve before any v0.3 work starts

The `cl-ergonomics` judge is **correct and I re-confirmed it live**. The working tree is *not* clean:

```
 M Makefile              |   5 ++-
 M lisp/src/codegen.lisp |  15 ++++---
 M lisp/src/ffi.lisp     | 114 ++++++++++++++++++++++++++++++-------
 ?? tests/bench.lisp
```

The diff implements ROADMAP §6 verbatim: `*pinnable*` probe + `pinned-vector-p` + `%memcpy`, pinned fast paths in `foreign-octets` / `call-with-bytes-arg` / `%take-vec-result`, element-wise fallbacks retained, and a signature change to `call-with-vec-arg` (adds a `lisp-type` argument) with the matching codegen call site. Someone did core surgery during a design-only exercise.

**Order of operations, non-negotiable:** (1) review this diff on its own branch, (2) add the tests in §6.A, (3) commit it as a standalone `perf(ffi): bulk :bytes/:vec marshalling` commit with attribution, (4) *then* start `examples/fetch`. Do not let it ride in on the v0.3 example commit. It is good work and it is required (§4.1) — it is not attributable as written.

---

## 1. CHOSEN API

**Thesis.** `examples/fetch` is a **pull-based async HTTP(S) client**: two handles (`Client` owning a tokio runtime + a readiness queue; `Req` owning one in-flight request), **zero `StoredCallback` params anywhere in the manifest**, **zero `block_on` anywhere in the crate**, and every Lisp-facing wait is a `Condvar::wait_timeout` capped at **100 ms** inside Rust with the loop written in Lisp. Bodies are pulled chunk-by-chunk as `:bytes`, or never cross at all via `sink_path`. Headers cross as the **raw CRLF field block as `:bytes` in both directions** — one encoding, lossless for duplicates, order, and obs-text. On top of that substrate sits `examples/fetch/http.lisp`, ~190 lines of pure Lisp: a CLOS condition hierarchy with slots, `retry-request` / `continue` restarts, `with-client`, and `(values body status headers)`. The substrate is what the boundary can prove; the veneer is what the user types. This is `streaming-scale`'s soundness with `idiomatic-cl`'s surface, `minimal-core`'s admission control, and the five defects all three shipped fixed structurally.

**Why the alternatives lost** (judges split 1–1; I chose the substrate winner and grafted the surface winner wholesale):

- **`streaming-scale` alone loses** on the surface the brief scores first: 10 positional params, NUL-joined header strings that silently mangle obs-text, and `req-error-kind` as a bare `u64` the user maps from a doc comment. It also caps waits at 60 s and holds a `std::sync::Mutex` across that wait — the exact uninterruptible-image failure it claims to design against. *Taken:* everything below the API line.
- **`idiomatic-cl` alone loses** on two fatal soundness bugs its own flagship call trips: `%collect` waits on `exchange-finished` before ever draining the 16-slot channel (any body over ~1 MB deadlocks into a spurious timeout), and `Exchange::body` drains chunks into a local `out` then drops it on the `!eof` error path, silently truncating every later read. *Taken:* the whole CL veneer, the `:bytes` header block, and the `*stored-callbacks*` cycle rule.
- **`minimal-core` alone loses** on the same terminal-state hole it asserts it does not have (`ChunkPipe::finish` reachable only from the task's own tail → a dropped task livelocks `(loop for chunk = ... while chunk)` forever, because empty ≠ NIL), plus an uncapped `wait_for` and one factual error about ECL trampolines. *Taken:* the governing invariant, admission control, `Semaphore::add_permits` as the sync backpressure hinge, and `shutdown_runtime`'s `try_current` guard.

**Four decisions where I overrode all three, each in one line:**

1. **No `StoredCallback` param exists in the manifest.** Verified at `lisp/src/codegen.lisp:422` — `ensure-stored-trampoline` runs at *binding-generation* time, so merely **declaring** a doorbell forces `compile-file` and a C toolchain on ECL whether or not it is ever called. Declaring none is the only real escape, and a 100 ms capped wait already delivers the latency the doorbell was buying. (`minimal-core` is factually wrong here; `idiomatic-cl` is right about the mechanism and pays the cost anyway.)
2. **Headers cross as `:bytes` in *both* directions**, not `:string` (streaming-scale/minimal-core lose obs-text through `from_utf8_lossy`) and not one-call-per-header (idiomatic-cl needs a third handle type for it). One encoding, symmetric, lossless, `HeaderValue::from_bytes` accepts exactly what `HeaderValue::as_bytes` emits.
3. **One mutex covers `state` + `chunks` together**, which retires streaming-scale's `queued.fetch_add`-before-`send` ordering proof entirely: `done()` reads both fields under one lock, so it cannot be wrongly true *or* stale. Simpler, and one fewer invariant for a solo maintainer to preserve.
4. **One Rust error type (`HttpError { kind, msg }`), not two.** Condition granularity comes from the Lisp side where conditions have slots and restarts; `kind` is a stable lowercase token (never a parsed prose prefix, never a bare `u64`).

---

## 2. RUST GLUE CODE — `examples/fetch/`

### `examples/fetch/Cargo.toml`

```toml
[package]
name = "fetch"                # NOT "http": would collide with the http crate
version = "0.1.0"
edition = "2021"
description = "rulisp example: an async HTTP(S) client for Common Lisp (reqwest + rustls)"
publish = false

[lib]
crate-type = ["cdylib"]

[dependencies]
rulisp = { path = "../../crates/rulisp" }

# default-features = false is load-bearing, not hygiene. It is what keeps
# tokio/signal and tokio/process out — "process" transitively enables the
# SIGCHLD driver, which installs a foreign signal handler and destabilises
# SBCL's signal-driven GC (BOUNDARY.md §7). Same rule that made examples/wasm
# pick wasmi over wasmtime.
tokio = { version = "1", default-features = false, features = [
    "rt-multi-thread", "net", "time", "sync", "fs", "io-util",
] }
tokio-util = { version = "0.7", default-features = false }
# rustls, not native-tls: the whole value proposition is HTTPS from Lisp with
# no system OpenSSL. webpki roots are baked into the cdylib, so a case-A blob
# user needs nothing on their machine but the .so.
reqwest = { version = "0.12", default-features = false, features = [
    "rustls-tls-webpki-roots", "http2", "gzip", "brotli", "stream", "charset",
] }
bytes = "1"
futures-util = { version = "0.3", default-features = false, features = ["std"] }
```

### `examples/fetch/audit.sh` — the dependency audit as a build gate

```sh
#!/bin/sh
# BOUNDARY.md §7 says "audit dependencies for sigaction". This makes the audit
# executable instead of a README claim. Wired into `make test-v03`.
set -e
cd "$(dirname "$0")"
cargo build --release
SO=target/release/libfetch.so
if nm -D --undefined-only "$SO" | grep -Eq 'sigaction|sigprocmask|bsd_signal'; then
    echo "FAIL: libfetch.so references a signal-disposition symbol" >&2; exit 1
fi
if cargo tree -e features | grep -Eq 'tokio feature "(signal|process)"'; then
    echo "FAIL: tokio signal/process feature enabled transitively" >&2; exit 1
fi
if cargo tree | grep -Eq 'openssl|native-tls'; then
    echo "FAIL: OpenSSL in the dependency graph" >&2; exit 1
fi
if grep -q 'block_on' src/lib.rs; then
    echo "FAIL: block_on in the glue — every wait must be Lisp-side" >&2; exit 1
fi
echo "audit ok"
```

### `examples/fetch/src/lib.rs`

```rust
//! examples/fetch — an async HTTP(S) client for Common Lisp: reqwest + rustls
//! on a tokio runtime owned by a rulisp handle.
//!
//! Why this example exists: CL's TLS story is OpenSSL dependency hell.
//! (fetch:make-client ...) and you have HTTPS, with zero system libraries and
//! no C toolchain on the user's machine.
//!
//! FOUR RULES, and everything else follows from them.
//!
//! R1  The queue is the truth. Body bytes are PULLED by a Lisp thread; nothing
//!     is ever pushed at Lisp. This crate registers ZERO callbacks, so no tokio
//!     thread is ever adopted into the Lisp world, no stored token can die
//!     mid-request, no Lisp condition can be signalled on a foreign thread, and
//!     ECL is byte-identical to SBCL with no trampoline compiled at load time
//!     (which merely DECLARING a StoredCallback param would force —
//!     lisp/src/codegen.lisp:422).
//!
//! R2  Terminal state is a Drop property, never a control-flow property. The
//!     happy path, abort(), a panic, a dropped future and runtime shutdown all
//!     reach a terminal state through TaskGuard, and all wake every waiter.
//!     Skipping this is what strands a Lisp thread forever.
//!
//! R3  No wait exceeds WAIT_CAP_MS. SBCL cannot deliver an interrupt to a
//!     thread inside a foreign call, so a long wait in Rust is an
//!     un-Ctrl-C-able image. The loop lives in Lisp; each slice returns
//!     control to Lisp frames, where a non-local exit is legal (BOUNDARY §6.4).
//!     `block_on` appears nowhere in this file and audit.sh enforces that.
//!
//! R4  A task holds Arc<Shared>, never &self. Freeing a handle mid-request can
//!     therefore never dangle. rustc also makes the classic async-FFI bug
//!     unwritable: &str/&[u8] params borrow Lisp memory for exactly one call
//!     and will not coerce into a 'static future.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures_util::StreamExt;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::runtime::{Builder, Handle as RtHandle, Runtime};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;

/// R3. 100 ms is the worst-case latency for C-c, SB-EXT:WITH-TIMEOUT and
/// BT:INTERRUPT-THREAD to be serviced by a thread waiting on this crate.
const WAIT_CAP_MS: u64 = 100;

// ---------------------------------------------------------------------------
// Errors. ONE Rust type -> one condition class, `fetch:http-error`. Granularity
// comes from `kind`, a stable token the Lisp veneer maps to a CLOS hierarchy —
// conditions want slots and restarts, which a Rust type name cannot carry.
//
// STABLE KINDS (API; adding one is additive, renaming one is a break):
//   usage connect tls timeout stalled cancelled too-large body decode io busy
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct HttpError {
    kind: &'static str,
    msg: String,
}

impl HttpError {
    fn new(kind: &'static str, msg: impl Into<String>) -> Self {
        HttpError { kind, msg: msg.into() }
    }
    fn usage(msg: impl Into<String>) -> Self {
        HttpError::new("usage", msg)
    }
    fn from_reqwest(e: &reqwest::Error) -> Self {
        let kind = if e.is_timeout() {
            "timeout"
        } else if e.is_connect() {
            // TLS handshake failures land here; the message carries the detail
            "connect"
        } else if e.is_decode() {
            "decode"
        } else if e.is_body() {
            "body"
        } else if e.is_builder() || e.is_request() {
            "usage"
        } else {
            "body"
        };
        HttpError::new(kind, e.to_string())
    }
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.kind, self.msg)
    }
}
impl std::error::Error for HttpError {}

// ---------------------------------------------------------------------------
// Header blocks: the raw HTTP/1.1 field block, as :bytes, in BOTH directions.
//
// Not a workaround for a missing (:vec :string) — strictly better than one.
// Header values are legally opaque octets (RFC 9110 §5.5 obs-text): a Latin-1
// filename in Content-Disposition survives here and is destroyed by any
// :string encoding. CR and LF cannot occur inside a name or value (the `http`
// crate rejects them at construction AND on parse, and obs-fold is dead), so
// the framing is unambiguous by protocol rather than by hope. Duplicates and
// wire order are preserved, which an alist would lose (Set-Cookie).
// ---------------------------------------------------------------------------

fn parse_header_block(block: &[u8]) -> Result<HeaderMap, HttpError> {
    let mut hm = HeaderMap::new();
    for line in block.split(|&b| b == b'\n') {
        let line = match line.strip_suffix(b"\r") { Some(l) => l, None => line };
        if line.is_empty() {
            continue;
        }
        let colon = line
            .iter()
            .position(|&b| b == b':')
            .ok_or_else(|| HttpError::usage("bad header line (want \"Name: value\")"))?;
        let name = HeaderName::from_bytes(&line[..colon])
            .map_err(|_| HttpError::usage("bad header name"))?;
        let raw = &line[colon + 1..];
        let start = raw.iter().position(|b| !matches!(b, b' ' | b'\t')).unwrap_or(raw.len());
        let value = HeaderValue::from_bytes(&raw[start..])
            .map_err(|_| HttpError::usage(format!("bad value for header {name}")))?;
        hm.append(name, value); // append, not insert: duplicates survive
    }
    Ok(hm)
}

fn render_header_block(h: &HeaderMap) -> Vec<u8> {
    let mut out = Vec::with_capacity(256);
    for (name, value) in h.iter() {
        out.extend_from_slice(name.as_str().as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(value.as_bytes()); // octets, never lossy UTF-8
        out.extend_from_slice(b"\r\n");
    }
    out
}

// ---------------------------------------------------------------------------
// Readiness queue: plain Mutex + Condvar, deliberately NOT a tokio channel.
// A Lisp consumer must never need a live runtime to receive, so a shut-down or
// freed Client can never wedge a Lisp thread. (This is the ~5-line hang that
// streaming-scale shipped: its ready_rx.recv() could never complete after
// shutdown because the Runtime that drove it was already gone.)
// ---------------------------------------------------------------------------

#[derive(Default)]
struct ReadyQ {
    q: Mutex<VecDeque<u64>>,
    cv: Condvar,
}

impl ReadyQ {
    fn push(&self, id: u64) {
        self.q.lock().unwrap().push_back(id);
        self.cv.notify_all();
    }
    fn pop(&self, wait: Duration, down: &AtomicBool) -> Option<u64> {
        let deadline = Instant::now() + wait;
        let mut q = self.q.lock().unwrap();
        loop {
            if let Some(id) = q.pop_front() {
                return Some(id);
            }
            if down.load(Ordering::Acquire) {
                return None; // fail fast, never hang on a dead client
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            q = self.cv.wait_timeout(q, deadline - now).unwrap().0;
        }
    }
    fn wake_all(&self) {
        let _g = self.q.lock().unwrap();
        self.cv.notify_all();
    }
}

// ---------------------------------------------------------------------------
// Shared: what the tokio task writes and the Lisp thread reads.
//
// ONE mutex covers chunks + terminal state together, which is why `done()` is
// exact with no memory-ordering argument at all: it reads both under one lock.
// Backpressure credit is a tokio Semaphore because `add_permits` is a SYNC
// method — that is the hinge that lets a Lisp thread grant credit to an async
// producer without a runtime.
// ---------------------------------------------------------------------------

struct PipeState {
    chunks: VecDeque<Bytes>,
    settled: bool,               // head arrived, or failed
    terminal: bool,              // task ended; no chunk can ever be added
    err: Option<HttpError>,
    status: u16,
    headers: Vec<u8>,
    closed: bool,                // consumer went away (Drop for Req)
}

struct Shared {
    id: u64,
    st: Mutex<PipeState>,
    cv: Condvar,
    credit: Semaphore,
    cap_chunks: usize,
    received: AtomicU64,
    total: AtomicU64,            // 0 = unknown (no Content-Length)
    cancel: CancellationToken,
    ready: Arc<ReadyQ>,
    down: Arc<AtomicBool>,
}

impl Shared {
    /// R2. Idempotent, callable from anywhere including Drop. Returns true the
    /// first time only.
    fn finish(&self, err: Option<HttpError>) -> bool {
        {
            let mut st = self.st.lock().unwrap();
            if st.terminal {
                return false;
            }
            st.terminal = true;
            st.settled = true;
            if st.err.is_none() {
                st.err = err;
            }
        }
        self.cv.notify_all();
        // ready-queue lock is taken only AFTER the pipe lock is released:
        // one lock order, no cycle, and no Lisp code ever runs under either.
        self.ready.push(self.id);
        true
    }

    fn set_head(&self, status: u16, headers: Vec<u8>) {
        {
            let mut st = self.st.lock().unwrap();
            st.status = status;
            st.headers = headers;
            st.settled = true;
        }
        self.cv.notify_all();
    }

    /// Producer side. Returns false when the consumer is gone.
    fn push(&self, b: Bytes) -> bool {
        {
            let mut st = self.st.lock().unwrap();
            if st.closed || st.terminal {
                return false;
            }
            st.chunks.push_back(b);
        }
        self.cv.notify_all();
        true
    }

    /// Consumer side (Drop for Req): stop the transfer and release the producer.
    fn close(&self) {
        {
            let mut st = self.st.lock().unwrap();
            st.closed = true;
            st.chunks.clear();
        }
        self.credit.add_permits(self.cap_chunks);
        self.cv.notify_all();
    }
}

/// R2 made structural. Drop runs on the happy path, on abort(), on a panic,
/// on runtime shutdown and on a dropped future. The permit rides along, so
/// admission credit is returned on every one of those paths too.
struct TaskGuard {
    sh: Arc<Shared>,
    _permit: OwnedSemaphorePermit,
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        self.sh.finish(Some(HttpError::new("cancelled", "request was cancelled")));
    }
}

fn capped(wait_ms: u64) -> Duration {
    Duration::from_millis(wait_ms.min(WAIT_CAP_MS))
}

/// Refuse a blocking call re-entered from a runtime thread with a typed
/// condition instead of letting tokio panic into catch_unwind. Unreachable
/// today (no callbacks exist), and three lines to keep it unreachable if a
/// push layer is ever added.
fn refuse_reentry() -> Result<(), HttpError> {
    if RtHandle::try_current().is_ok() {
        return Err(HttpError::usage(
            "blocking fetch call from a tokio thread — pass wait-ms 0 there",
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

#[rulisp::handle]
pub struct Client {
    rt: Mutex<Option<Runtime>>,
    handle: RtHandle,
    http: reqwest::Client,
    permits: Arc<Semaphore>,
    max_in_flight: u64,
    queue_chunks: u64,
    max_body_bytes: u64,
    stall_ms: u64,
    root: CancellationToken,
    next_id: AtomicU64,
    ready: Arc<ReadyQ>,
    down: Arc<AtomicBool>,
}

#[rulisp::export]
impl Client {
    /// (fetch:make-client 4 128 8 268435456 30000 "myapp/1.0")
    ///
    /// WORKER-THREADS tokio workers; at most MAX-IN-FLIGHT concurrent requests
    /// (admission control — spawning past it is a loud refusal, never a silent
    /// queue); QUEUE-CHUNKS body chunks buffered per request (the backpressure
    /// bound); MAX-BODY-BYTES refuses a response larger than this with kind
    /// "too-large" (in-process FFI has no crash isolation — an OOM here kills
    /// the Lisp image, BOUNDARY.md §7); STALL-MS fails a request whose consumer
    /// has stopped draining.
    #[rulisp(constructor)]
    pub fn new(
        worker_threads: u64,
        max_in_flight: u64,
        queue_chunks: u64,
        max_body_bytes: u64,
        stall_ms: u64,
        user_agent: Option<&str>,
    ) -> Result<Client, HttpError> {
        let rt = Builder::new_multi_thread()
            .worker_threads(worker_threads.clamp(1, 64) as usize)
            .thread_name("fetch-worker")
            .enable_io()
            .enable_time() // NOT enable_all(): keeps the intent auditable
            .build()
            .map_err(|e| HttpError::new("io", format!("tokio runtime: {e}")))?;
        let http = reqwest::Client::builder()
            .user_agent(user_agent.unwrap_or("rulisp-fetch/0.1").to_owned())
            .use_rustls_tls()
            .connect_timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| HttpError::new("usage", format!("reqwest client: {e}")))?;
        let max_in_flight = max_in_flight.clamp(1, 65536);
        Ok(Client {
            handle: rt.handle().clone(),
            rt: Mutex::new(Some(rt)),
            http,
            permits: Arc::new(Semaphore::new(max_in_flight as usize)),
            max_in_flight,
            queue_chunks: queue_chunks.clamp(1, 4096),
            max_body_bytes: if max_body_bytes == 0 { u64::MAX } else { max_body_bytes },
            stall_ms: if stall_ms == 0 { 30_000 } else { stall_ms },
            root: CancellationToken::new(),
            next_id: AtomicU64::new(1),
            ready: Arc::new(ReadyQ::default()),
            down: Arc::new(AtomicBool::new(false)),
        })
    }

    /// The id of the next request that reached a terminal state, or NIL.
    /// This is the epoll of the design: 300 concurrent requests, one Lisp
    /// thread. WAIT-MS is capped at 100 — put the loop in Lisp.
    pub fn next_ready(&self, wait_ms: u64) -> Result<Option<u64>, HttpError> {
        refuse_reentry()?;
        if self.down.load(Ordering::Acquire) {
            return Err(HttpError::usage("client has been shut down"));
        }
        Ok(self.ready.pop(capped(wait_ms), &self.down))
    }

    pub fn in_flight(&self) -> u64 {
        self.max_in_flight - self.permits.available_permits() as u64
    }

    pub fn is_down(&self) -> bool {
        self.down.load(Ordering::Acquire)
    }

    /// Stop everything. Idempotent. CALL THIS before save-lisp-and-die and
    /// before re-running use-crate. GRACE-MS is capped at 2000: this may be
    /// called from a Lisp thread and must not wedge it.
    pub fn shutdown(&self, grace_ms: u64) {
        self.down.store(true, Ordering::Release);
        self.root.cancel();
        let rt = self.rt.lock().unwrap().take();
        if let Some(rt) = rt {
            shutdown_runtime(rt, grace_ms.min(2000));
        }
        self.ready.wake_all(); // release anyone in next-ready
    }

    /// A loopback HTTP/1.1 server, so this example's own test suite is
    /// hermetic — no network in CI. Returns the base URL.
    /// Paths: /ok /bytes/N /drip/N/MS /delay/MS /status/N /dup-headers
    ///        /obs-text /no-length/N
    pub fn start_test_server(&self) -> Result<String, HttpError> {
        let (tx, rx) = std::sync::mpsc::channel();
        self.handle.spawn(async move {
            match tokio::net::TcpListener::bind("127.0.0.1:0").await {
                Ok(l) => {
                    let _ = tx.send(Ok(l.local_addr().unwrap().port()));
                    loop {
                        match l.accept().await {
                            Ok((s, _)) => { tokio::spawn(serve_one(s)); }
                            Err(_) => break,
                        }
                    }
                }
                Err(e) => { let _ = tx.send(Err(e.to_string())); }
            }
        });
        match rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(port)) => Ok(format!("http://127.0.0.1:{port}")),
            Ok(Err(e)) => Err(HttpError::new("io", e)),
            Err(_) => Err(HttpError::new("io", "test server did not start")),
        }
    }
}

/// Dropping a Runtime BLOCKS until blocking tasks finish, and PANICS outright
/// if it happens inside a runtime context. Neither is acceptable on a Lisp
/// finalizer thread; the free shim would swallow the panic (BOUNDARY.md §2)
/// and leak the runtime.
fn shutdown_runtime(rt: Runtime, grace_ms: u64) {
    if RtHandle::try_current().is_ok() {
        std::thread::spawn(move || drop(rt));
    } else {
        rt.shutdown_timeout(Duration::from_millis(grace_ms));
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.down.store(true, Ordering::Release);
        self.root.cancel();
        if let Some(rt) = self.rt.lock().unwrap().take() {
            // A finalizer must NEVER wait on the network.
            rt.shutdown_background();
        }
        self.ready.wake_all();
    }
}

// ---------------------------------------------------------------------------
// Req — one request. `Req` IS the promise: req-wait / req-read / req-cancel,
// and Drop == cancel, so rulisp:free and the GC finalizer are the cancellation
// path for free. Nothing in core is needed for that.
// ---------------------------------------------------------------------------

#[rulisp::handle]
pub struct Req {
    sh: Arc<Shared>,
    abort: tokio::task::AbortHandle,
}

#[rulisp::export]
impl Req {
    /// (fetch:make-req client "GET" url headers-block body sink-path timeout-ms)
    ///
    /// Returns IMMEDIATELY; the transfer runs on tokio. A constructor on the
    /// PRODUCED type taking the producing handle as an ordinary parameter is
    /// the only shape v0.2 can express (a &self method may not return a
    /// handle), and it is enough.
    ///
    /// HEADERS is the raw CRLF field block as octets ("" for none). BODY is
    /// NIL or octets — for uploads beyond a few MB, that is out of scope in
    /// v0.3 (see the scope fence). SINK-PATH streams the response straight to
    /// disk and the bytes never cross the boundary at all. TIMEOUT-MS is
    /// reqwest's whole-request timeout; 0 disables it.
    #[rulisp(constructor)]
    pub fn start(
        client: &Client,
        method: &str,
        url: &str,
        headers: &[u8],
        body: Option<&[u8]>,
        sink_path: Option<&str>,
        timeout_ms: u64,
    ) -> Result<Req, HttpError> {
        if client.down.load(Ordering::Acquire) {
            return Err(HttpError::usage("client has been shut down"));
        }
        // Validate and COPY out of Lisp memory synchronously, before we can
        // possibly return. `&[u8]` borrows the Lisp heap for exactly this call
        // (BOUNDARY.md §4); .to_vec() is the contract, not a wart. Forgetting
        // it is not a bug you can write — a borrowed slice will not coerce
        // into a 'static future.
        let m = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|_| HttpError::usage(format!("bad HTTP method {method:?}")))?;
        let u = reqwest::Url::parse(url)
            .map_err(|e| HttpError::usage(format!("bad url {url:?}: {e}")))?;
        let hm = parse_header_block(headers)?;
        let owned_body = body.map(|b| b.to_vec());
        let sink = sink_path.map(str::to_owned);

        // Admission control: the answer to "what if the user never drains".
        // Bounded, loud, no silent dropping. The permit lives in TaskGuard, so
        // every terminal path returns it.
        let permit = Arc::clone(&client.permits)
            .try_acquire_owned()
            .map_err(|_| {
                HttpError::new(
                    "busy",
                    format!(
                        "{} requests already in flight (max); free or drain some first",
                        client.max_in_flight
                    ),
                )
            })?;

        let id = client.next_id.fetch_add(1, Ordering::Relaxed);
        let sh = Arc::new(Shared {
            id,
            st: Mutex::new(PipeState {
                chunks: VecDeque::new(),
                settled: false,
                terminal: false,
                err: None,
                status: 0,
                headers: Vec::new(),
                closed: false,
            }),
            cv: Condvar::new(),
            credit: Semaphore::new(client.queue_chunks as usize),
            cap_chunks: client.queue_chunks as usize,
            received: AtomicU64::new(0),
            total: AtomicU64::new(0),
            cancel: client.root.child_token(),
            ready: Arc::clone(&client.ready),
            down: Arc::clone(&client.down),
        });

        let mut rb = client.http.request(m, u).headers(hm);
        if timeout_ms > 0 {
            rb = rb.timeout(Duration::from_millis(timeout_ms));
        }
        if let Some(b) = owned_body {
            rb = rb.body(b);
        }

        let task_sh = Arc::clone(&sh);
        let max_body = client.max_body_bytes;
        let stall = Duration::from_millis(client.stall_ms);
        let join = client.handle.spawn(async move {
            let guard = TaskGuard { sh: Arc::clone(&task_sh), _permit: permit };
            let r = run(rb, &task_sh, sink, max_body, stall).await;
            task_sh.finish(r.err());
            drop(guard); // explicit: the finish above already won the race
        });

        Ok(Req { sh, abort: join.abort_handle() })
    }

    pub fn id(&self) -> u64 { self.sh.id }

    /// Head arrived (or the request failed): status and headers are readable.
    pub fn settled(&self) -> bool { self.sh.st.lock().unwrap().settled }

    /// Terminal AND nothing left buffered. Exact — both fields under one lock.
    /// Guaranteed to become true eventually on EVERY path, including abort,
    /// panic, client shutdown and a dropped future (R2).
    pub fn done(&self) -> bool {
        let st = self.sh.st.lock().unwrap();
        st.terminal && st.chunks.is_empty()
    }

    pub fn failed(&self) -> bool { self.sh.st.lock().unwrap().err.is_some() }

    /// A stable token, never a parsed message prefix. The veneer maps it to a
    /// CLOS class. NIL when the request has not failed.
    pub fn error_kind(&self) -> Option<String> {
        self.sh.st.lock().unwrap().err.as_ref().map(|e| e.kind.to_string())
    }

    pub fn error_message(&self) -> Option<String> {
        self.sh.st.lock().unwrap().err.as_ref().map(|e| e.msg.clone())
    }

    pub fn status(&self) -> u16 { self.sh.st.lock().unwrap().status }

    /// The raw response field block as octets: wire order, duplicates intact,
    /// obs-text intact. Decode in Lisp under your own policy.
    pub fn headers(&self) -> Vec<u8> { self.sh.st.lock().unwrap().headers.clone() }

    /// First value for NAME (case-insensitive), decoded ISO-8859-1 — the
    /// single-name lookup done in Rust, which covers 95% of uses.
    pub fn header(&self, name: &str) -> Option<String> {
        let st = self.sh.st.lock().unwrap();
        for line in st.headers.split(|&b| b == b'\n') {
            let line = match line.strip_suffix(b"\r") { Some(l) => l, None => line };
            let colon = line.iter().position(|&b| b == b':')?;
            if line[..colon].eq_ignore_ascii_case(name.as_bytes()) {
                let v = &line[colon + 1..];
                let s = v.iter().position(|b| !matches!(b, b' ' | b'\t')).unwrap_or(v.len());
                return Some(v[s..].iter().map(|&b| b as char).collect());
            }
        }
        None
    }

    pub fn received(&self) -> u64 { self.sh.received.load(Ordering::Relaxed) }

    pub fn total(&self) -> Option<u64> {
        match self.sh.total.load(Ordering::Relaxed) { 0 => None, n => Some(n) }
    }

    pub fn buffered(&self) -> u64 {
        self.sh.st.lock().unwrap().chunks.len() as u64
    }

    /// Pull up to MAX-BYTES of body, waiting at most WAIT-MS (capped at 100).
    ///
    ///   octets -> data
    ///   NIL    -> nothing available right now; ask REQ-DONE and loop
    ///   error  -> the request failed (buffered bytes are delivered FIRST,
    ///             then the condition surfaces — never dropped on the floor)
    ///
    /// MAX-BYTES is a soft coalescing target: a single chunk is never split.
    pub fn read(&self, max_bytes: u64, wait_ms: u64) -> Result<Option<Vec<u8>>, HttpError> {
        if wait_ms > 0 {
            refuse_reentry()?;
        }
        let deadline = Instant::now() + capped(wait_ms);
        let mut st = self.sh.st.lock().unwrap();
        loop {
            if !st.chunks.is_empty() {
                let mut out: Vec<u8> = Vec::new();
                let mut n = 0usize;
                while let Some(c) = st.chunks.pop_front() {
                    out.extend_from_slice(&c);
                    n += 1;
                    if out.len() as u64 >= max_bytes.max(1) {
                        break;
                    }
                }
                drop(st);
                self.sh.credit.add_permits(n); // sync: needs no runtime
                return Ok(Some(out));
            }
            if let Some(e) = &st.err {
                return Err(e.clone()); // buffered data was already drained above
            }
            if st.terminal {
                return Ok(None); // clean EOF
            }
            if self.sh.down.load(Ordering::Acquire) {
                return Err(HttpError::usage("client has been shut down"));
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            st = self.sh.cv.wait_timeout(st, deadline - now).unwrap().0;
        }
    }

    /// Wait until the transfer has ENDED (not necessarily drained). T if it
    /// has. WAIT-MS capped at 100 — put the loop in Lisp. Use this for
    /// sink-path downloads; for streaming use REQ-SETTLED then REQ-READ.
    pub fn wait(&self, wait_ms: u64) -> Result<bool, HttpError> {
        refuse_reentry()?;
        let deadline = Instant::now() + capped(wait_ms);
        let mut st = self.sh.st.lock().unwrap();
        loop {
            if st.terminal {
                return Ok(true);
            }
            if self.sh.down.load(Ordering::Acquire) {
                return Err(HttpError::usage("client has been shut down"));
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(false);
            }
            st = self.sh.cv.wait_timeout(st, deadline - now).unwrap().0;
        }
    }

    /// Ask for cancellation. The request still reaches a terminal state, with
    /// kind "cancelled" — no request ever vanishes. Idempotent, never blocks.
    pub fn cancel(&self) {
        self.sh.cancel.cancel();
        self.abort.abort();
    }
}

impl Drop for Req {
    fn drop(&mut self) {
        // Freeing the handle — explicitly or from a GC finalizer on any
        // thread — cancels the transfer. Both calls are non-blocking, so no
        // finalizer ever waits on the network.
        self.sh.close();
        self.sh.cancel.cancel();
        self.abort.abort();
    }
}

// ---------------------------------------------------------------------------
// The task
// ---------------------------------------------------------------------------

async fn run(
    rb: reqwest::RequestBuilder,
    sh: &Arc<Shared>,
    sink: Option<String>,
    max_body: u64,
    stall: Duration,
) -> Result<(), HttpError> {
    let resp = tokio::select! {
        biased;
        _ = sh.cancel.cancelled() => return Err(HttpError::new("cancelled", "cancelled")),
        r = rb.send() => r.map_err(|e| HttpError::from_reqwest(&e))?,
    };

    if let Some(n) = resp.content_length() {
        sh.total.store(n, Ordering::Relaxed);
        if n > max_body {
            return Err(HttpError::new(
                "too-large",
                format!("Content-Length {n} exceeds max-body-bytes {max_body}"),
            ));
        }
    }
    sh.set_head(resp.status().as_u16(), render_header_block(resp.headers()));

    let mut file = match &sink {
        Some(p) => Some(
            tokio::fs::File::create(p)
                .await
                .map_err(|e| HttpError::new("io", format!("create {p}: {e}")))?,
        ),
        None => None,
    };

    let mut stream = resp.bytes_stream();
    loop {
        let item = tokio::select! {
            biased;
            _ = sh.cancel.cancelled() => return Err(HttpError::new("cancelled", "cancelled")),
            i = stream.next() => i,
        };
        let Some(item) = item else { break };
        let chunk = item.map_err(|e| HttpError::from_reqwest(&e))?;
        if chunk.is_empty() {
            continue;
        }
        let got = sh.received.fetch_add(chunk.len() as u64, Ordering::Relaxed)
            + chunk.len() as u64;
        if got > max_body {
            return Err(HttpError::new(
                "too-large",
                format!("body exceeded max-body-bytes {max_body}"),
            ));
        }
        match &mut file {
            Some(f) => f
                .write_all(&chunk)
                .await
                .map_err(|e| HttpError::new("io", format!("write: {e}")))?,
            None => {
                // Backpressure with a third net behind it. Net 1: the bounded
                // credit. Net 2: hyper stops polling -> TCP zero-window -> the
                // server throttles. Net 3: this stall timer, which fails the
                // request instead of pinning a socket forever.
                let permit = tokio::select! {
                    biased;
                    _ = sh.cancel.cancelled() =>
                        return Err(HttpError::new("cancelled", "cancelled")),
                    p = sh.credit.acquire() => match p {
                        Ok(p) => p,
                        Err(_) => return Ok(()), // closed
                    },
                    _ = tokio::time::sleep(stall) =>
                        return Err(HttpError::new(
                            "stalled",
                            "consumer stopped draining the body")),
                };
                permit.forget(); // returned by read() via add_permits
                if !sh.push(chunk) {
                    return Ok(()); // consumer gone; Drop already closed us
                }
            }
        }
    }
    if let Some(mut f) = file {
        f.flush().await.map_err(|e| HttpError::new("io", format!("flush: {e}")))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Loopback test server (hermetic CI). ~60 lines of raw HTTP/1.1; no server
// framework, no extra dependency, no signal handlers.
// ---------------------------------------------------------------------------

async fn serve_one(mut s: tokio::net::TcpStream) {
    let mut buf = vec![0u8; 8192];
    let mut n = 0;
    while n < buf.len() {
        match s.read(&mut buf[n..]).await {
            Ok(0) => return,
            Ok(k) => {
                n += k;
                if buf[..n].windows(4).any(|w| w == b"\r\n\r\n") { break; }
            }
            Err(_) => return,
        }
    }
    let req = String::from_utf8_lossy(&buf[..n]).to_string();
    let path = req.split_whitespace().nth(1).unwrap_or("/").to_string();
    let seg: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let _ = match seg.as_slice() {
        ["bytes", n] => {
            let n: usize = n.parse().unwrap_or(0);
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {n}\r\nContent-Type: application/octet-stream\r\n\r\n");
            let mut out = head.into_bytes();
            out.extend(std::iter::repeat(b'x').take(n));
            s.write_all(&out).await
        }
        ["drip", n, ms] => {
            let n: usize = n.parse().unwrap_or(0);
            let ms: u64 = ms.parse().unwrap_or(0);
            let _ = s.write_all(
                format!("HTTP/1.1 200 OK\r\nContent-Length: {n}\r\n\r\n").as_bytes()).await;
            let mut sent = 0;
            while sent < n {
                let k = (n - sent).min(8192);
                if s.write_all(&vec![b'y'; k]).await.is_err() { return; }
                sent += k;
                tokio::time::sleep(Duration::from_millis(ms)).await;
            }
            Ok(())
        }
        ["delay", ms] => {
            tokio::time::sleep(Duration::from_millis(ms.parse().unwrap_or(0))).await;
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await
        }
        ["status", c] => s.write_all(
            format!("HTTP/1.1 {c} X\r\nContent-Length: 5\r\n\r\nboom!").as_bytes()).await,
        ["dup-headers"] => s.write_all(
            b"HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 2\r\n\r\nok").await,
        // a Latin-1 filename: 0xE9 is legal obs-text and is NOT valid UTF-8
        ["obs-text"] => s.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Disposition: attachment; filename=caf\xE9.txt\r\nContent-Length: 2\r\n\r\nok").await,
        ["no-length", n] => {
            let n: usize = n.parse().unwrap_or(0);
            let _ = s.write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").await;
            let _ = s.write_all(&vec![b'z'; n]).await;
            return;
        }
        _ => s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await,
    };
}

rulisp::module! {
    name: "fetch",
    handles: [Client, Req],
    fns: [
        Client::new, Client::next_ready, Client::in_flight, Client::is_down,
        Client::shutdown, Client::start_test_server,
        Req::start, Req::id, Req::settled, Req::done, Req::failed,
        Req::error_kind, Req::error_message, Req::status, Req::headers,
        Req::header, Req::received, Req::total, Req::buffered,
        Req::read, Req::wait, Req::cancel,
    ],
}
```

**Generated Lisp surface** (from the verified `make-{kebab}` / `{kebab}-{fn-kebab}` rule at `crates/rulisp-macros/src/lib.rs:955-962`): `fetch:make-client`, `client-next-ready`, `client-in-flight`, `client-is-down`, `client-shutdown`, `client-start-test-server`, `fetch:make-req`, `req-id`, `req-settled`, `req-done`, `req-failed`, `req-error-kind`, `req-error-message`, `req-status`, `req-headers`, `req-header`, `req-received`, `req-total`, `req-buffered`, `req-read`, `req-wait`, `req-cancel`; condition class `fetch:http-error`. **22 exports, 2 handles, one constructor per handle type** — which also sidesteps the duplicate-constructor bug entirely rather than relying on the fix in §4.2.

### `examples/fetch/http.lisp` — the veneer (this is the API users see)

```lisp
;;; The dexador-shaped surface. ~190 lines of pure Lisp; needs nothing from
;;; rulisp core. The generated fetch: package is the substrate, this is the API.
(defpackage #:http
  (:use #:cl)
  (:shadow #:get #:delete)
  (:export #:make-client #:close-client #:with-client #:*client*
           #:request #:get #:post #:put #:delete #:download #:stream-to
           #:http-error #:transport-error #:timeout-error #:connection-error
           #:tls-error #:cancelled-error #:stalled-error #:too-large-error
           #:busy-error #:request-failed #:client-error #:server-error
           #:http-status #:http-headers #:http-body #:http-url
           #:retry-request))
(in-package #:http)

;;; --- conditions -----------------------------------------------------------
;;; Granularity comes from here, not from Rust: the manifest's :errors keys on
;;; the Rust TYPE of E, so one fallible fn can raise exactly one class. The
;;; discriminator crosses as DATA (req-error-kind) and becomes a class here —
;;; which is better anyway, because CL conditions want slots and restarts.

(define-condition http-error (error)
  ((url :initarg :url :initform nil :reader http-url)))

(define-condition transport-error (http-error)
  ((kind   :initarg :kind   :initform nil :reader transport-error-kind)
   (detail :initarg :detail :initform ""  :reader transport-error-detail))
  (:report (lambda (c s) (format s "~A while requesting ~A: ~A"
                                 (transport-error-kind c) (http-url c)
                                 (transport-error-detail c)))))

(define-condition timeout-error    (transport-error) ())
(define-condition connection-error (transport-error) ())
(define-condition tls-error        (connection-error) ())
(define-condition cancelled-error  (transport-error) ())
(define-condition stalled-error    (transport-error) ())
(define-condition too-large-error  (transport-error) ())
(define-condition busy-error       (transport-error) ())

(define-condition request-failed (http-error)
  ((status  :initarg :status  :reader http-status)
   (headers :initarg :headers :initform nil :reader http-headers)
   (body    :initarg :body    :initform nil :reader http-body))
  (:report (lambda (c s) (format s "HTTP ~D for ~A" (http-status c) (http-url c)))))

(define-condition client-error (request-failed) ())   ; 4xx
(define-condition server-error (request-failed) ())   ; 5xx

(defun %kind-class (kind)
  (cond ((string= kind "timeout")   'timeout-error)
        ((string= kind "connect")   'connection-error)
        ((string= kind "tls")       'tls-error)
        ((string= kind "cancelled") 'cancelled-error)
        ((string= kind "stalled")   'stalled-error)
        ((string= kind "too-large") 'too-large-error)
        ((string= kind "busy")      'busy-error)
        (t 'transport-error)))

;;; --- client ---------------------------------------------------------------

(defvar *client* nil)

(defun make-client (&key (worker-threads 4) (max-in-flight 128) (queue-chunks 8)
                         (max-body-bytes (* 256 1024 1024)) (stall-ms 30000)
                         (user-agent "rulisp-fetch/0.1"))
  (fetch:make-client worker-threads max-in-flight queue-chunks
                     max-body-bytes stall-ms user-agent))

(defun close-client (c &key (grace-ms 1000))
  (fetch:client-shutdown c grace-ms)
  (rulisp:free c))

(defmacro with-client ((var &rest options) &body body)
  `(let ((,var (make-client ,@options)))
     (unwind-protect (let ((*client* ,var)) ,@body)
       (close-client ,var))))

;;; --- header block <-> alist, ISO-8859-1 (cannot fail; obs-text survives) ---

(defun %latin1 (o s e) (map 'string #'code-char (subseq o s e)))

(defun %parse-headers (block)
  (let ((out '()) (start 0) (len (length block)))
    (loop while (< start len)
          for eol = (or (search #(13 10) block :start2 start) len)
          do (let ((colon (position 58 block :start start :end eol)))
               (when colon
                 (let ((vs (loop for i from (1+ colon) below eol
                                 while (member (aref block i) '(32 9))
                                 finally (return i))))
                   (push (cons (string-downcase (%latin1 block start colon))
                               (%latin1 block vs eol))
                         out))))
             (setf start (+ eol 2)))
    (nreverse out)))

(defun %render-headers (alist)
  (let ((s (make-array 0 :element-type '(unsigned-byte 8)
                         :adjustable t :fill-pointer 0)))
    (loop for (k . v) in alist
          do (loop for ch across (format nil "~A: ~A~C~C"
                                         (string-downcase (string k))
                                         (princ-to-string v) #\Return #\Newline)
                   do (vector-push-extend (char-code ch) s)))
    (coerce s '(simple-array (unsigned-byte 8) (*)))))

;;; --- the wait loop: R3. Every slice is <=100ms IN RUST, the loop is HERE, so
;;; C-c / with-timeout / interrupt-thread land within 100ms and unwind through
;;; Lisp frames only.

(defun %deadline (secs)
  (+ (get-internal-real-time) (round (* secs internal-time-units-per-second))))

(defun %expired-p (deadline) (> (get-internal-real-time) deadline))

(defun %signal-if-failed (r url)
  (let ((kind (fetch:req-error-kind r)))
    (when kind
      (error (%kind-class kind) :url url :kind kind
             :detail (or (fetch:req-error-message r) "")))))

;;; --- the entry point ------------------------------------------------------

(defun request (method url &key headers content (timeout 30) (client *client*)
                             (max-bytes (* 128 1024)) force-binary)
  "Perform METHOD URL; return (VALUES BODY STATUS HEADERS).
Restarts: RETRY-REQUEST re-sends; CONTINUE returns a failed 4xx/5xx response."
  (loop
    (restart-case
        (return (%once method url headers content timeout client max-bytes
                       force-binary))
      (retry-request ()
        :report (lambda (s) (format s "Send ~A ~A again." method url))))))

(defun %once (method url headers content timeout client max-bytes force-binary)
  (unless client (error "no HTTP client: bind HTTP:*CLIENT* or pass :client"))
  (let ((r (fetch:make-req client (string-upcase (string method)) url
                           (%render-headers headers)
                           (and content (%octets content))
                           nil (round (* 1000 timeout)))))
    ;; C-c, a deadline, or any condition below lands here: freeing the request
    ;; aborts the tokio task and kills the transfer. Nothing keeps running.
    (unwind-protect
         (let ((deadline (%deadline (+ timeout 5)))
               (body (make-array 0 :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0)))
           ;; ONE loop drains as it flows: a body larger than the chunk queue
           ;; can never deadlock, because we never wait for "finished" before
           ;; reading. (This is the bug that broke idiomatic-cl's flagship.)
           (loop
             (let ((c (fetch:req-read r max-bytes 100)))
               (cond (c (let ((n (fill-pointer body)))
                          (adjust-array body (+ n (length c)) :fill-pointer (+ n (length c)))
                          (replace body c :start1 n)))
                     ((fetch:req-done r) (return))
                     ((%expired-p deadline)
                      (fetch:req-cancel r)
                      (error 'timeout-error :url url :kind "timeout"
                             :detail (format nil "no completion within ~As (Lisp deadline)"
                                             timeout))))))
           (%signal-if-failed r url)
           (let* ((status (fetch:req-status r))
                  (hs (%parse-headers (fetch:req-headers r)))
                  (octets (coerce body '(simple-array (unsigned-byte 8) (*))))
                  (out (if force-binary octets (%maybe-decode octets hs))))
             (when (>= status 400)
               (restart-case
                   (error (if (< status 500) 'client-error 'server-error)
                          :url url :status status :headers hs :body out)
                 (continue () :report "Return the failed response anyway.")))
             (values out status hs)))
      (rulisp:free r))))

(defun get    (url &rest a) (apply #'request :get url a))
(defun post   (url &rest a) (apply #'request :post url a))
(defun put    (url &rest a) (apply #'request :put url a))
(defun delete (url &rest a) (apply #'request :delete url a))

(defun download (url path &key headers (timeout 3600) (client *client*))
  "Stream URL straight to PATH. The bytes never cross the boundary; peak Lisp
heap is zero regardless of size."
  (let ((r (fetch:make-req client "GET" url (%render-headers headers)
                           nil path (round (* 1000 timeout))))
        (deadline (%deadline timeout)))
    (unwind-protect
         (progn
           (loop until (fetch:req-wait r 100)
                 do (when (%expired-p deadline)
                      (fetch:req-cancel r)
                      (error 'timeout-error :url url :kind "timeout"
                             :detail "download deadline")))
           (%signal-if-failed r url)
           (values (fetch:req-status r) (fetch:req-received r)))
      (rulisp:free r))))

(defun stream-to (url sink &key headers (timeout 300) (client *client*)
                                (max-bytes (* 128 1024)))
  "Call SINK with each body chunk as it arrives; return (VALUES STATUS HEADERS).
Memory is bounded by the client's queue-chunks no matter how large the body."
  (let ((r (fetch:make-req client "GET" url (%render-headers headers) nil nil
                           (round (* 1000 timeout))))
        (deadline (%deadline timeout)))
    (unwind-protect
         (progn
           (loop until (fetch:req-settled r)
                 do (fetch:req-wait r 100)
                    (when (%expired-p deadline)
                      (fetch:req-cancel r)
                      (error 'timeout-error :url url :kind "timeout"
                             :detail "no response head")))
           (%signal-if-failed r url)
           (let ((status (fetch:req-status r))
                 (hs (%parse-headers (fetch:req-headers r))))
             (loop
               (let ((c (fetch:req-read r max-bytes 100)))
                 (cond (c (funcall sink c))
                       ((fetch:req-done r) (return))
                       ((%expired-p deadline)
                        (fetch:req-cancel r)
                        (error 'timeout-error :url url :kind "timeout"
                               :detail "body stalled")))))
             (%signal-if-failed r url)
             (values status hs)))
      (rulisp:free r))))

;;; Image dump: rulisp protects the boundary (the session counter invalidates
;;; every pre-dump handle without a foreign call). The veneer must protect its
;;; own cache — and must shut the runtime down BEFORE SBCL quiesces.
(uiop:register-image-dump-hook
 (lambda () (when *client* (close-client *client*) (setf *client* nil))))
(uiop:register-image-restore-hook (lambda () (setf *client* nil)) nil)
```

---

## 3. CL SESSION — the exact REPL transcript

```lisp
CL-USER> (ql:quickload :rulisp)
CL-USER> (rulisp:use-crate #p"~/src/rulisp/examples/fetch/")
#<RULISP:CRATE "fetch" gen 1 abi 1 :: 22 fns, 2 handles, package FETCH>
CL-USER> (load "~/src/rulisp/examples/fetch/http.lisp")

;;; ------------------------------------------------------------------ 1. GET
CL-USER> (defparameter *c* (http:make-client))
*C*
CL-USER> (setf http:*client* *c*)

CL-USER> (http:get "https://example.org/")
"<!doctype html>
<html>..."
200
(("content-type" . "text/html; charset=UTF-8") ("content-length" . "1256")
 ("date" . "Mon, 03 Aug 2026 04:11:02 GMT") ("server" . "ECS (dcb/7F5C)"))

;;; -------------------------------------------------- 2. errors are conditions
CL-USER> (handler-case (http:get "https://no-such-host.invalid/")
           (http:connection-error (e) (list :kind (http:transport-error-kind e)
                                            :url  (http:http-url e))))
(:KIND "connect" :URL "https://no-such-host.invalid/")

CL-USER> (http:get "https://httpbin.org/status/503")
; Debugger invoked on HTTP:SERVER-ERROR in thread #<THREAD "main">:
;   HTTP 503 for https://httpbin.org/status/503
; restarts:
;   0: [CONTINUE]       Return the failed response anyway.
;   1: [RETRY-REQUEST]  Send GET https://httpbin.org/status/503 again.
;   2: [ABORT]          Exit debugger.
0
"service unavailable"
503
(("content-type" . "text/html") ("content-length" . "19"))

CL-USER> (handler-bind ((http:connection-error
                          (lambda (e) (declare (ignore e))
                            (sleep 1) (invoke-restart 'http:retry-request))))
           (http:get "https://flaky.example.com/"))
"ok"
200
(("content-length" . "2"))

;;; ------------------------------------------------------------- 3. timeouts
CL-USER> (http:get "https://httpbin.org/delay/10" :timeout 2)
; Debugger invoked on HTTP:TIMEOUT-ERROR in thread #<THREAD "main">:
;   timeout while requesting https://httpbin.org/delay/10: operation timed out
0

;; the OUTER Lisp deadline, which also covers a wedged Rust side, is +5s and
;; fires as a Lisp condition — never as a hang:
CL-USER> (handler-case (http:get "http://127.0.0.1:9/" :timeout 1)
           (http:transport-error (e) (http:transport-error-kind e)))
"connect"

;;; ----------------------------------------------- 4. cancellation is just C-c
CL-USER> (http:get "https://httpbin.org/delay/60")
^C
; Interactive interrupt at #x7F3A0011AB20.
;   [Condition of type SB-SYS:INTERACTIVE-INTERRUPT]
0
;; The interrupt was serviced within 100 ms (the wait cap). The unwind ran in
;; pure Lisp frames; UNWIND-PROTECT freed the Req; Drop cancelled the tokio
;; task and closed the socket. Nothing is still downloading behind your back:
CL-USER> (fetch:client-in-flight *c*)
0

;; explicit cancellation, with the "buffered bytes are delivered first" rule:
CL-USER> (let ((r (fetch:make-req *c* "GET" "http://127.0.0.1:8080/drip/50000000/50"
                                  (%render-headers nil) nil nil 0)))
           (fetch:req-read r 65536 100)          ; pull one chunk
           (fetch:req-cancel r)
           (sleep 0.2)
           (list :failed (fetch:req-failed r)
                 :kind   (fetch:req-error-kind r)
                 :drained (loop for c = (fetch:req-read r 65536 0) while c
                                sum (length c))
                 :done   (fetch:req-done r)))
(:FAILED T :KIND "cancelled" :DRAINED 16384 :DONE T)
;; and the condition surfaces only after the buffer is empty:
CL-USER> (handler-case (fetch:req-read *r* 65536 0)
           (fetch:http-error (e) (princ-to-string e)))
"Rust error HttpError in fetch:req-read: cancelled: request was cancelled"

;;; -------------------------------- 5. streaming: constant memory, any size
CL-USER> (with-open-file (out #p"/tmp/big.bin" :direction :output
                              :element-type '(unsigned-byte 8) :if-exists :supersede)
           (http:stream-to "http://127.0.0.1:8080/bytes/104857600"
                           (lambda (c) (write-sequence c out))))
200
(("content-length" . "104857600") ("content-type" . "application/octet-stream"))
;; peak Lisp heap: 8 chunks x 128 KB. Peak Rust heap: the same. 100 MB body.

;;; --------------------- 6. and for the truly large case, don't cross at all
CL-USER> (http:download "https://cdn.example.org/ubuntu.iso" "/tmp/ubuntu.iso")
200
4718592000
;; peak Lisp heap for the body: 0 bytes.

;;; ------------------------------ 7. 300 concurrent requests, ONE Lisp thread
CL-USER> (let ((reqs (make-hash-table)) (done 0) (bytes 0))
           (dotimes (i 300)
             (let ((r (fetch:make-req *c* "GET" "http://127.0.0.1:8080/bytes/4096"
                                      (%render-headers nil) nil nil 15000)))
               (setf (gethash (fetch:req-id r) reqs) r)))
           (format t "~&in flight: ~D~%" (fetch:client-in-flight *c*))
           (loop while (< done 300)
                 for id = (fetch:client-next-ready *c* 100)   ; <=100ms slices
                 when id
                   do (let ((r (gethash id reqs)))
                        (loop for c = (fetch:req-read r 65536 0)  ; non-blocking
                              while c do (incf bytes (length c)))
                        (when (fetch:req-done r)
                          (incf done) (remhash id reqs) (rulisp:free r))))
           (list done bytes (fetch:client-in-flight *c*)))
in flight: 300
(300 1228800 0)
;; No Lisp thread was created. C-c works throughout, because the loop is here.

;;; ------------------------------------- 8. admission control, loudly refused
CL-USER> (let ((held (loop repeat 128 collect
                           (fetch:make-req *c* "GET" "http://127.0.0.1:8080/delay/5000"
                                           (%render-headers nil) nil nil 0))))
           (handler-case (fetch:make-req *c* "GET" "http://127.0.0.1:8080/ok"
                                         (%render-headers nil) nil nil 0)
             (fetch:http-error (e) (prog1 (princ-to-string e)
                                     (mapc #'rulisp:free held)))))
"Rust error HttpError in fetch:make-req: busy: 128 requests already in flight
 (max); free or drain some first"

;;; ----------------------------- 9. the user stops draining (backpressure net 3)
CL-USER> (let ((r (fetch:make-req *c* "GET" "http://127.0.0.1:8080/drip/50000000/10"
                                  (%render-headers nil) nil nil 0)))
           (fetch:req-read r 4096 100)
           (sleep 3)                                  ; never drain again
           (list (fetch:req-error-kind r) (fetch:req-buffered r) (fetch:req-done r)))
("stalled" 0 NIL)     ; socket closed, memory reclaimed, handle still valid

;;; ------------------------------------- 10. a hostile body meets the byte cap
CL-USER> (http:with-client (c :max-body-bytes 1048576)
           (handler-case (http:get "http://127.0.0.1:8080/no-length/104857600" :client c)
             (http:too-large-error (e) (http:transport-error-detail e))))
"body exceeded max-body-bytes 1048576"

;;; ------------------- 11. obs-text and duplicate headers survive intact
CL-USER> (nth-value 2 (http:get "http://127.0.0.1:8080/dup-headers"))
(("set-cookie" . "a=1") ("set-cookie" . "b=2") ("content-length" . "2"))
;; an alist keyed by name would have destroyed this; so would (:vec :string).
CL-USER> (cdr (assoc "content-disposition"
                     (nth-value 2 (http:get "http://127.0.0.1:8080/obs-text"))
                     :test #'string=))
"attachment; filename=cafÃ©.txt"   ; octet 0xE9 preserved; NOT U+FFFD

;;; ------------------------------------- 12. dump / reload discipline
CL-USER> (fetch:client-shutdown *c* 1000)
CL-USER> (length (bt:all-threads))
1                                   ; tokio workers are gone
CL-USER> (http:get "https://example.org/")
; Debugger invoked on FETCH:HTTP-ERROR:
;   Rust error HttpError in fetch:make-req: usage: client has been shut down
0
CL-USER> (rulisp:free *c*)
CL-USER> (rulisp:use-crate #p"~/src/rulisp/examples/fetch/")
#<RULISP:CRATE "fetch" gen 2 abi 1 :: 22 fns, 2 handles, package FETCH>
;; a gen-1 handle used through gen-2 bindings:
CL-USER> (fetch:client-in-flight *stale*)
; Debugger invoked on RULISP:STALE-HANDLE-ERROR:
;   Stale handle (in fetch:client-in-flight): handle gen 1, crate gen 2
0
```

---

## 4. CORE FEATURES REQUIRED

### **ZERO. No new boundary feature is required — say it loudly.**

**No wire change. No ABI bump (stays ABI 1). No new manifest key. No new type token. No macro attribute. No golden-fixture change.** Every crossing this example makes is already in the closed vocabulary of BOUNDARY.md §11, and I re-verified each one against HEAD: handle params on constructors (`fn_params` pushes non-self `HandleRef` into `call_args`), `:bytes` in and out (`tests/suite/v02.lisp` exercises both), `(:option :string)`, `(:option :bytes)`, `(:option scalar)`, `:u16`, `:u64`, `:bool`, and a `Result<T, E>` per function. **Both judges reached this independently and I concur.**

All four candidate gaps are **refuted as load-bearing**, and three of them would make this example *worse*:

| Candidate | Verdict |
|---|---|
| `:bytes` in callback params | **Refuted.** The design pulls; body bytes never travel through a callback. Push additionally costs one foreign-thread adoption per chunk (~65k for a 4 GB download), has no backpressure, and cannot report a mid-body error (a callback returns `()`). |
| `(:vec :string)` | **Refuted, and strictly worse.** It would force UTF-8 validation on legally-opaque obs-text header values. The `:bytes` field block is lossless for duplicates, order *and* octets. |
| Cancellation support in core | **Refuted.** `CancellationToken` + `impl Drop` makes `rulisp:free` and the GC finalizer the cancellation path for free. Cancellation is a property of the work, not of the boundary. |
| `Vec<Vec<u8>>` | **Refuted.** Nothing in an HTTP client wants it. |
| Multiple return values | **Refuted for v0.3.** `(values body status headers)` is assembled in the veneer from three crossings that cost nanoseconds against an HTTP request. |

### What IS required before this example can ship — four items, none of them boundary features

**Ordered. All zero-wire, ABI-1 additive. Total: roughly 2 developer-days including tests.**

---

**4.1 — Bulk `:bytes` / `:vec` marshalling. REQUIRED. Already written; must be committed properly first.**

- **What.** Pinned-vector + `memcpy` fast paths in `foreign-octets`, `call-with-bytes-arg`, `call-with-vec-arg`, `%take-vec-result`, with the element-wise path retained as the non-pinnable fallback and a once-per-element-type `pinnable-p` probe.
- **Why load-bearing.** At HEAD-minus-worktree these copy one element at a time through `cffi:mem-aref` (~7–10 ns/byte, measured in the untracked `tests/bench.lisp`). A flagship whose headline is megabyte HTTPS bodies cannot be gated on a 150–300 MB/s marshaller. This is ROADMAP §6 and this example is its demand case.
- **Wire impact.** **None.** No manifest key, no ABI change, no type token, no macro change. Golden fixtures untouched. Purely a Lisp-side representation change on both sides of an existing `(ptr, len)` transfer. It stays inside BOUNDARY §4 because pinning is dynamic-extent and Rust may not retain the pointer.
- **Sketch.** *Rust macro side:* **nothing.** *CL side:* it is already written in the working tree — `lisp/src/ffi.lisp` (`*pinnable*`, `pinnable-p`, `pinned-vector-p`, `%memcpy`, rewritten `foreign-octets` / `call-with-bytes-arg`) and `lisp/src/codegen.lisp` (`%take-vec-result` bulk path, `call-with-vec-arg` gains a `lisp-type` argument plus its call site). **Action: review, test (§6.A), attribute, commit standalone. Do not inherit it silently.**

---

**4.2 — Reject duplicate `:lisp-name` in the manifest. REQUIRED (silent wrong code in shipped v0.2.1).**

- **What.** A manifest carrying two functions with the same `:lisp-name` must signal `rulisp:manifest-error`.
- **Why load-bearing.** Confirmed live: `commit-bindings` (`lisp/src/crate.lisp:271-273`) does `(setf (symbol-function sym) fn)` in a loop with no duplicate check, and `crates/rulisp-macros/src/lib.rs:960` hardcodes `format!("make-{kebab}")` from the impl type — so two `#[rulisp(constructor)]` fns on one type both compute `make-<type>`, the second silently wins, and the first stays in the manifest and the `.so` unreachable from Lisp with **no diagnostic anywhere**. All three designs hit this demand case. `examples/fetch` routes around it (one constructor per handle type), which is exactly why it must be fixed independently rather than papered over.
- **Wire impact.** **None** — it only adds a rejection to an already-invalid manifest. Existing golden fixtures have no duplicates and are unaffected.
- **Sketch.** *Rust macro side:* nothing (the macro may keep emitting the collision; the loader is the gate — and a Rust-side check cannot see across impl blocks anyway). *CL side:* in `parse-manifest` (`lisp/src/manifest.lisp:120`), after the `:functions` list is built, one `equal` hash-table pass → `(error 'manifest-error :message "duplicate lisp name ~A (~A and ~A)")`. I place it in `parse-manifest` rather than `prepare-bindings` (where both judges put it) because it is a manifest-level invariant, it fires before any symbol is interned, and it becomes a one-line `fx.*` fixture test exactly like the twelve already in `tests/suite/m2.lisp`.

---

**4.3 — `#[rulisp(constructor)]` on a `&self` method must be a real diagnostic. REQUIRED.**

- **What.** Reject it at macro-expansion time with a message naming the workaround.
- **Why load-bearing.** `fn_params` classifies the receiver into `self_expr`, and `CallKind::Ctor`'s `quote! { <#self_ty>::#method(#(#call_args),*) }` (`crates/rulisp-macros/src/lib.rs:538`) **never uses it** — the receiver is silently dropped and the author gets a raw `E0061` from inside macro-generated code. "This handle produces that handle" is the first thing every async/cursor/iterator author writes; it is the first thing all three designs hit. Every future handle-producing example pays this toll.
- **Wire impact.** **None** — compile-time diagnostic only.
- **Sketch.** *Rust macro side:* in `export_impl`, when `is_ctor` and `m.sig.receiver().is_some()`, emit `compile_error!("rulisp: a constructor cannot take &self — take the producing handle as an ordinary parameter, e.g. fn start(client: &Client, ...) -> Result<Req, E>")`. ~6 lines next to the existing `parse_nested_meta` block. *CL side:* nothing.

---

**4.4 — Three sentences of contract text in BOUNDARY.md. REQUIRED (docs, zero code).**

- **What.** §7: (a) every blocking export must take a `wait_ms` and **cap it in Rust**, because SBCL cannot deliver an interrupt to a thread inside a foreign call — the loop belongs in Lisp; (b) a blocking export must refuse re-entry from a foreign runtime thread (`Handle::try_current`) with a typed condition rather than let the runtime panic into `catch_unwind`. §10: (c) **`save-lisp-and-die` SUCCEEDS with live foreign threads** — SBCL does not see unadopted foreign threads, so there is *no* guardrail; any glue crate that owns threads must export an explicit shutdown and the example must call it from a dump hook.
- **Why load-bearing.** Two of the three designs violated (a) in their own flagship helper after correctly arguing for it. (c) is measured, surprising, and currently undocumented.
- **Wire impact.** **None.**
- **Sketch.** Prose in `BOUNDARY.md` §7/§10 plus a cross-reference from `docs/usage.md`, which also gains the `*stored-callbacks*` rule (§5, row "token death") even though this example registers none.

---

## 5. RISK TABLE

| # | Risk | Where the design handles it | Test that proves it |
|---|---|---|---|
| 1 | **Threads** — tokio workers vs. Lisp threads | R1: zero callbacks in the manifest, so **no tokio thread ever enters Lisp**. Lisp threads only marshal, lock briefly, and wait ≤100 ms on a `Condvar`. All handle state is behind `Mutex`/atomics so concurrent `&self` calls are sound (BOUNDARY §5). Documented single-reader rule per `Req` and single-poller rule for `client-next-ready`. | `v03.threads.no-adoption`, `v03.threads.concurrent-clients` |
| 2 | **Threads / interruptibility** — an un-Ctrl-C-able image | R3: `WAIT_CAP_MS = 100`, applied in `read`, `wait`, `next_ready` via `capped()`; `block_on` appears nowhere and `audit.sh` greps for it. The loop is in `http.lisp`, so a non-local exit unwinds through Lisp frames only. | `v03.interrupt.c-c-lands-fast`, plus the `audit.sh` gate |
| 3 | **Threads / re-entry** — a blocking call from a runtime thread | `refuse_reentry()` → `HttpError{kind:"usage"}` instead of tokio's panic. Unreachable today; three lines to keep it so. | `v03.usage.reentry-refused` (calls `req-read` from inside a tokio-driven path in a debug-only hook; asserted as a code-inspection + `audit.sh` invariant if not directly reachable) |
| 4 | **GC** — a Lisp thread parked in Rust; a finalizer that blocks | `Condvar::wait_timeout` **releases** the mutex while waiting, so `SIG_STOP_FOR_GC` parks the thread with no Rust lock held and the predicate loop absorbs the spurious wakeup. `Drop for Req` = `close` + `cancel` + `abort`, all non-blocking. `Drop for Client` uses `shutdown_background()` — **never** a plain `drop(Runtime)` (which blocks, and panics inside a runtime context; the free shim would swallow that panic per BOUNDARY §2 and leak the runtime). | `v03.gc.storm-during-transfer`, `v03.gc.finalizer-never-blocks`, `v03.gc.abandoned-requests-reclaimed` |
| 5 | **Reload** — `use-crate` twice | Gen-1 handles refuse through gen-2 wrappers (`stale-handle-error`) without dereferencing. Gen-1's runtime is **recoverable, not leaked**: rulisp routes frees to the birth generation, so `(rulisp:free *old*)` or GC runs gen-1's `Drop`. Sound only because rulisp never `dlclose`s (BOUNDARY §9) — cite this example there as the worked reason that rule is load-bearing. Documented rule: `client-shutdown` before reload. | `v03.reload.stale-handle-signals`, `v03.reload.old-runtime-reclaimed` |
| 6 | **Dump** — `save-lisp-and-die` | Measured fact: the dump **succeeds** with live foreign threads; there is no guardrail. Handled by `client-shutdown` from `uiop:register-image-dump-hook` in `http.lisp`, and by BOUNDARY §10 text (§4.4c). On restore rulisp bumps the session counter, so every pre-dump handle refuses use and frees without a foreign call. | `v03.dump.shutdown-hook-quiesces` (assert `(length (bt:all-threads))` = 1 after the hook), `v03.dump.restored-handles-refuse` |
| 7 | **Token death** — a stored callback dies mid-request | **Non-event by construction:** this crate declares zero `StoredCallback` params, so no token exists. The rule is documented anyway in `docs/usage.md` for future push layers: `*stored-callbacks*` holds closures **strongly and forever**, so a registered closure must capture only inert synchronization objects — never the struct that owns the token — and unregistration must go through a finalizer capturing the token alone. Otherwise the token is immortal, the finalizer never runs, and the runtime leaks for the image's life. | `v03.manifest.no-stored-callbacks` (assert the parsed manifest contains no `:stored-callback` param — this is what keeps ECL parity a *property*, not a promise) |
| 8 | **Cancellation race** — cancel vs. completion vs. free | R2 `TaskGuard`: terminal state is a `Drop` property, so abort, panic, runtime shutdown, client shutdown and normal completion all reach terminal and all `notify_all` + push to the readiness queue. `Shared::finish` is gated on `st.terminal` under the same lock that guards `chunks`, so it is idempotent and `done()` is exact. Buffered bytes are delivered **before** the error surfaces. Free-vs-in-flight-call is handled by rulisp's own cell state machine (deferred free). | `v03.cancel.terminal-always-reached`, `v03.cancel.drains-then-signals`, `v03.cancel.no-livelock-after-drop` |
| 9 | **Big bodies** — megabytes and gigabytes | Three answers, in order of size: `sink_path` (peak Lisp heap **0**), `req-read` chunked pull at 64–256 KiB (peak = `queue_chunks` × chunk), and the buffered veneer path which **drains as it flows** so it can never deadlock on a body larger than the queue. Hard ceiling from `max_body_bytes` (checked against `Content-Length` *and* against running `received`) because in-process FFI has no crash isolation — an OOM kills the image. Never `:string` for a body: a 1-Mchar SBCL string costs 4 MB vs 1 MB of octets. | `v03.body.100mb-streams-constant-memory`, `v03.body.buffered-path-no-deadlock`, `v03.body.max-bytes-refused`, `v03.body.sink-zero-lisp-heap` |
| 10 | **Big bodies / never drained** | Three nested nets: bounded credit (`Semaphore`) → hyper stops polling → TCP zero-window → `stall_ms` watchdog fails the request with kind `"stalled"`, closing the socket and reclaiming memory. Plus admission control (`try_acquire_owned` → kind `"busy"`) bounding the *count* of outstanding requests, which the byte cap does not. | `v03.backpressure.stall-fires`, `v03.backpressure.bounded-buffer`, `v03.admission.refuses-loudly` |
| 11 | **ECL** — cannot adopt foreign threads | **Zero degradation, and it is structural, not argued.** No `StoredCallback` param exists anywhere in the manifest, so `ensure-stored-trampoline` (`lisp/src/codegen.lisp:422`) is never reached at binding-generation time — **no trampoline is compiled and no C toolchain is needed at load**. Every export behaves identically. | `v03.ecl.*` — the whole suite re-run under ECL by `make test-v03-ecl`; plus `v03.manifest.no-stored-callbacks` as the guard that keeps it true |
| 12 | **Signals** — a dependency installing a handler | `default-features = false` on tokio and reqwest (`process` transitively enables the SIGCHLD driver); rustls not native-tls. Enforced by `audit.sh` as a **build gate**, not a README claim: `nm -D` for `sigaction`/`sigprocmask`/`bsd_signal`, `cargo tree -e features` for `tokio feature "signal"|"process"`, `cargo tree` for `openssl`. | `v03.signals.dispositions-unchanged` (byte-compare `sigaction` dispositions before dlopen / after dlopen / after a TLS handshake / after a GC storm) + `audit.sh` in `make test-v03` |
| 13 | **obs-text corruption** — silent data loss | Header block is `:bytes` in **both** directions; `HeaderValue::from_bytes` / `as_bytes` never validate UTF-8; the veneer decodes ISO-8859-1, which cannot fail. | `v03.headers.obs-text-roundtrip`, `v03.headers.duplicates-preserved` |
| 14 | **Use-after-free** — task outliving the handle | R4: a task holds `Arc<Shared>`, never `&self`, so `Box::from_raw` can never dangle. `&str`/`&[u8]` params are copied synchronously before `start` returns, and rustc refuses to let a borrowed slice enter a `'static` future. | `v03.lifetime.free-mid-transfer`, `v03.lifetime.response-outlives-client` |

---

## 6. TEST PLAN

New file `tests/suite/v03.lisp`, registered in `lisp/rulisp.asd` (`rulisp/test` components, after `v02`). New runner `tests/run-v03.lisp` modelled on `tests/run-m4.lisp`, setting `rulisp/test::*fetch-dir*` to `examples/fetch/` and starting the loopback server once via `(fetch:client-start-test-server *c*)` into `*base*`. New Makefile targets:

```make
test-v03:
	cd examples/fetch && sh audit.sh
	$(SBCL) --non-interactive --load tests/run-v03.lisp
test-v03-ecl:
	$(ECL) --shell tests/run-v03.lisp        # same suite, zero expected diffs
```

`(def-suite* :rulisp-v03)`. Every test below states what a **failure** looks like, because a green suite that cannot fail proves nothing.

### A. Core fixes (run against `examples/wordbag`, in `tests/suite/v02.lisp` — they gate §4.1–4.3)

| Test | Asserts | A failure looks like |
|---|---|---|
| `core.bulk-bytes-roundtrip` | 1 MB, 8 MB and 0-byte octet vectors survive `REV` twice bit-exactly; `(live-allocs)` unchanged across 100 iterations | a truncated or shifted buffer (a `memcpy` length in elements vs. bytes), or a leaked allocation from an early return past `dealloc` |
| `core.bulk-vec-roundtrip` | `DELTAS` on a 100k-element `(signed-byte 32)` vector matches the element-wise path exactly | element-size confusion in `%take-vec-result` — the classic `(* len elt-size)` bug — showing as garbage in the tail |
| `core.bulk-fallback` | with `pinnable-p` stubbed to `nil`, every above test still passes | the element-wise fallback rotted while the fast path was written |
| `core.bulk-inbound-not-retained` | after `call-with-bytes-arg` returns, mutating the Lisp vector cannot affect Rust's copy | Rust retained the pinned pointer — a BOUNDARY §4 violation, and the one way this optimisation could be unsound |
| `fx.duplicate-lisp-name` | `(signals rulisp:manifest-error (parse "...:functions ((… :lisp-name \"f\" …) (… :lisp-name \"f\" …))"))` | no condition — meaning §4.2 is unfixed and one of the two exports is silently unreachable |
| `core.ctor-with-self-rejected` | a `trybuild`-style compile-fail fixture in `crates/rulisp-macros/tests/` asserts the `compile_error!` text | a raw `E0061` from inside macro-generated code, i.e. §4.3 regressed |

### B. `examples/fetch` — contract and lifecycle

| Test | Asserts | A failure looks like |
|---|---|---|
| `v03.manifest.no-stored-callbacks` | the parsed manifest contains **zero** `:stored-callback` params | someone added a doorbell; ECL silently starts requiring a C toolchain at load, and rows 7/11 of the risk table stop being true |
| `v03.cancel.terminal-always-reached` | for each of {normal completion, `req-cancel`, `rulisp:free` mid-transfer, `client-shutdown` mid-transfer, GC of an abandoned `Req`}: `req-done` becomes T within 2 s and `client-in-flight` returns to 0 | `req-done` stuck NIL forever — the exact `TaskGuard` bug streaming-scale measured (`in-flight` pinned at 96) and the exact livelock minimal-core and idiomatic-cl shipped |
| `v03.cancel.no-livelock` | with the producer killed by `client-shutdown`, the documented loop `(loop for c = (req-read r 65536 100) while (or c (not (req-done r))) ...)` terminates in <1 s | the loop spins forever — minimal-core's §5.4 claim was false in exactly this way |
| `v03.cancel.drains-then-signals` | after `req-cancel`, buffered bytes are returned first and only then does `req-read` signal | bytes dropped on the floor (idiomatic-cl's `Exchange::body` silently truncating) |
| `v03.lifetime.free-mid-transfer` | free a `Req` during a `/drip/…` download; no crash, `client-in-flight` → 0, `(live-allocs)` stable | a segfault (task holding `&self`) or a permit leak (guard bypassed) |
| `v03.usage.after-shutdown` | every export on a shut-down client returns `usage:` within 200 ms and **never hangs** | a wedged Lisp thread — streaming-scale's ~5-line `down`-check omission |
| `v03.usage.wait-is-capped` | `(req-wait r 600000)` returns in <200 ms | someone removed `capped()`; the image is now un-Ctrl-C-able for ten minutes |

### C. `examples/fetch` — data fidelity and size

| Test | Asserts | A failure looks like |
|---|---|---|
| `v03.headers.obs-text-roundtrip` | `/obs-text` → the `content-disposition` value contains `(code-char #xE9)` | U+FFFD — a lossy `:string` crept back into the header path |
| `v03.headers.duplicates-preserved` | `/dup-headers` → two `set-cookie` entries, in wire order | an alist or a map collapsed them; the classic naive-HTTP-binding bug |
| `v03.headers.request-roundtrip` | a request block with a duplicate name and a trailing-whitespace value arrives at the test server intact | asymmetric encoding between the in and out directions |
| `v03.body.buffered-path-no-deadlock` | `(http:get ".../bytes/104857600")` with `queue-chunks 2` returns 100 MB of `x` | it times out — idiomatic-cl's fatal deadlock, and the single most important regression to keep out |
| `v03.body.100mb-streams-constant-memory` | `stream-to` on 100 MB with `queue-chunks 8`: `(sb-ext:get-bytes-consed)` growth stays under 32 MB | the pipe grew without bound, i.e. backpressure is off |
| `v03.body.sink-zero-lisp-heap` | `download` of 100 MB: file size exact, Lisp bytes-consed growth <1 MB | the sink path started routing through the pipe |
| `v03.body.max-bytes-refused` | `/no-length/104857600` with `max-body-bytes 1048576` → `too-large-error`, and RSS growth <8 MB | no cap, or a cap checked only against `Content-Length` (which a chunked hostile peer omits) |
| `v03.backpressure.stall-fires` | drip + no draining for `stall-ms` + 1 s → kind `"stalled"`, `req-buffered` 0 | net 3 missing; the socket is pinned until the whole-request timeout |
| `v03.admission.refuses-loudly` | request `max-in-flight`+1 → kind `"busy"`; after freeing one, the next succeeds | silent queueing (unbounded memory) or a permit that is not returned on the cancel path |

### D. `examples/fetch` — host integration

| Test | Asserts | A failure looks like |
|---|---|---|
| `v03.threads.no-adoption` | `(length (bt:all-threads))` is 1 before, during and after 300 concurrent requests | a tokio thread was adopted — impossible today, and this is the tripwire if a push layer is ever added |
| `v03.threads.concurrent-clients` | 8 Lisp threads × 50 requests on one `Client`, all 400 complete, `(live-allocs)` stable | a data race or a lock-order inversion between the pipe lock and the ready-queue lock |
| `v03.gc.storm-during-transfer` | 5 × `(gc :full t)` with 100k live objects during a 100 MB stream: byte-exact result | a Rust lock held across a `SIG_STOP_FOR_GC` park, showing as a stall or a hang |
| `v03.gc.abandoned-requests-reclaimed` | 10 abandoned 20 MB streams + `(gc :full t)` → `client-in-flight` 0 within 5 s | the finalizer path skips `TaskGuard`, or blocks |
| `v03.interrupt.c-c-lands-fast` | a second thread `bt:interrupt-thread`s a thread inside `(http:get ".../delay/30000")`; the interrupt is serviced in <300 ms and the unwind frees the `Req` | >300 ms means a wait is uncapped; a leaked `Req` means `unwind-protect` is mis-placed |
| `v03.reload.stale-handle-signals` | after a second `use-crate`, a gen-1 handle signals `rulisp:stale-handle-error` | a gen-1 handle silently used through gen-2 wrappers — the one true memory-safety cliff |
| `v03.reload.old-runtime-reclaimed` | after reload, `(rulisp:free *gen1-client*)` drops OS thread count back to baseline | gen-1 workers leak for the life of the image |
| `v03.dump.shutdown-hook-quiesces` | run the dump hook, then assert `(length (bt:all-threads))` = 1 and `client-is-down` = T | a dump taken with live foreign threads — silently permitted by SBCL, and the reason §4.4c exists |
| `v03.signals.dispositions-unchanged` | `sigaction` dispositions for SIGILL/ABRT/BUS/FPE/SEGV/PIPE/CHLD/PROF/INT/TERM are byte-identical at four checkpoints | a dependency installed a handler; SBCL's GC is now unstable in ways that surface days later |
| `v03.ecl.parity` | the entire suite under ECL 21.2.1, zero skips, and **zero trampolines compiled at load** | any skip means the ECL-parity claim is marketing |

---

## 7. WHAT WE ARE NOT DOING IN v0.3

**Boundary features — refused, with cause (do not reopen without a new demand case):**
- `:bytes` (or any non-scalar) in callback params. No demand case survives the pull design.
- `(:vec :string)`. Strictly worse than the `:bytes` field block for the only real demand case anyone produced.
- Cancellation primitives in core. `Drop` + `CancellationToken` already make `rulisp:free` and the GC finalizer the cancellation path.
- `Vec<Vec<u8>>`, nested containers, multiple return values, tagged-enum → condition-subclass mapping.
- Constructor `&key` arguments (ROADMAP §3). The 7-parameter `Req::start` is the substrate; `http:request` is the API. Do not let a self-inflicted arity argument reopen a deferred-with-cause item.
- `#[rulisp(constructor, name = "...")]`. ~10 lines and genuinely nice, but §4.2 makes duplicate names a hard error and this example has one constructor per handle type, so nothing is blocked. **Deferred to v0.4**, where the first two-constructor handle type will justify it.
- `#[rulisp(on_unload)]` / a per-crate before-reload hook. Would make dump/reload discipline structural instead of documented. Genuinely nice-to-have; **not** load-bearing. v0.4 at the earliest.
- Anything that would `dlclose`. It would turn this example into instant UB (BOUNDARY §9).

**Example scope — cut deliberately:**
- **The push/doorbell layer.** No `client-on-event`, no `StoredCallback` anywhere. It buys latency the 100 ms readiness poll already provides and costs ECL parity, four risk categories, and the `*stored-callbacks*` cycle hazard. If it is ever added it must be **opt-in, additive, and unset on ECL** — and `v03.manifest.no-stored-callbacks` must be deleted deliberately, not silently.
- **Streaming uploads (`source_path`) and multipart.** Uploads go through `body: Option<&[u8]>`, documented as "fine to a few MB, wrong at 100 MB". Cuts one constructor parameter and a whole test axis.
- **Cookie jar, redirect policy configuration, proxy configuration, HTTP/3, connection-pool tuning knobs, per-request retry policy.** reqwest's defaults, exposed as-is.
- **Zero-copy `:string`.** §4.1 covers `:bytes` and `:vec` only; bodies are octets by design, so `:string` bulk marshalling has no demand case here.
- **A release-profile benchmark suite.** The `target/debug` throughput numbers from the design phase must not be quoted in the example's docs. If a number ships, it comes from a release build with a documented method — otherwise no number ships at all.
- **`response-chunk offset len` random access into a buffered body.** The pull stream plus `sink_path` covers every case; a second body-access API is surface without a demand case.
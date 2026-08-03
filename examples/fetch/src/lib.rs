//! examples/fetch — an async HTTP(S) client for Common Lisp: reqwest over
//! rustls on a tokio runtime owned by a rulisp handle.
//!
//! Why it looks like this (design panel, docs/design/v03-async-plan.md):
//!
//! * **Pull, not push.** No `StoredCallback` appears anywhere. Body bytes
//!   are pulled chunk-by-chunk by the Lisp side. Pushing would cost a
//!   foreign-thread adoption per chunk, has no natural backpressure, and —
//!   decisively — merely *declaring* a stored callback would force
//!   `compile-file` and a C toolchain on ECL at binding-generation time.
//! * **Every wait is capped in Rust; the loop lives in Lisp.** A Lisp
//!   thread inside a foreign call cannot be interrupted, so an uncapped
//!   wait makes the image unkillable (BOUNDARY §7). Waits here cap at
//!   `WAIT_CAP_MS`; callers loop, where interrupts and restarts work.
//! * **Terminal state is guaranteed by a Drop guard.** However a request
//!   ends — success, error, cancel, `rulisp:free`, GC of an abandoned
//!   handle, runtime shutdown — `TaskGuard::drop` marks it settled, wakes
//!   waiters, returns the admission permit and posts to the ready queue.
//!   Without that, `(loop … while (not (req-done r)))` can livelock.
//! * **Headers cross as the raw CRLF field block in `:bytes`, both ways.**
//!   Lossless for duplicates, order and obs-text octets; a `:string`
//!   encoding would mangle legal header values into U+FFFD.
//!
//! It needs no rulisp feature that 0.2 doesn't already have.

mod error;
mod testserver;

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use tokio::io::AsyncWriteExt;
use tokio::runtime::{Builder, Runtime};
use tokio_util::sync::CancellationToken;

pub use error::HttpError;

/// No single foreign call may park a Lisp thread longer than this.
const WAIT_CAP_MS: u64 = 100;

fn capped(ms: u64) -> Duration {
    Duration::from_millis(ms.min(WAIT_CAP_MS))
}

/// A blocking export must never run on a runtime worker: that would
/// deadlock the runtime it is waiting on. Cheap and defensive — Lisp
/// threads are never runtime threads today.
fn refuse_reentry() -> Result<(), HttpError> {
    if tokio::runtime::Handle::try_current().is_ok() {
        return Err(HttpError::usage(
            "blocking export called from inside the runtime",
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Header block codec: name ": " value CRLF, repeated. No trailing blank line.
// ---------------------------------------------------------------------------

fn encode_headers(h: &HeaderMap) -> Vec<u8> {
    let mut out = Vec::new();
    for (name, value) in h.iter() {
        out.extend_from_slice(name.as_str().as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(value.as_bytes());
        out.extend_from_slice(b"\r\n");
    }
    out
}

fn decode_headers(block: &[u8]) -> Result<HeaderMap, HttpError> {
    let mut map = HeaderMap::new();
    for line in block.split(|&b| b == b'\n') {
        let line = match line.strip_suffix(b"\r") {
            Some(l) => l,
            None => line,
        };
        if line.is_empty() {
            continue;
        }
        let colon = line
            .iter()
            .position(|&b| b == b':')
            .ok_or_else(|| HttpError::request("header line without a colon"))?;
        let name = std::str::from_utf8(&line[..colon])
            .map_err(|_| HttpError::request("header name is not ASCII"))?
            .trim();
        let value = &line[colon + 1..];
        let value = match value.iter().position(|&b| b != b' ' && b != b'\t') {
            Some(i) => &value[i..],
            None => &value[value.len()..],
        };
        let name = HeaderName::from_bytes(name.as_bytes())
            .map_err(|e| HttpError::request(format!("bad header name: {e}")))?;
        // from_bytes, not from_str: obs-text values are legal and not UTF-8
        let value = HeaderValue::from_bytes(value)
            .map_err(|e| HttpError::request(format!("bad header value: {e}")))?;
        map.append(name, value);
    }
    Ok(map)
}

// ---------------------------------------------------------------------------
// Per-request shared state
// ---------------------------------------------------------------------------

struct State {
    /// the task has reached its terminal state and will produce nothing more
    settled: bool,
    err: Option<HttpError>,
    status: u16,
    headers: Vec<u8>,
    head_done: bool,
    chunks: VecDeque<Vec<u8>>,
    buffered: u64,
    eof: bool,
}

struct Shared {
    id: u64,
    st: Mutex<State>,
    cv: Condvar,
    received: AtomicU64,
    /// -1 when the server sent no Content-Length
    total: AtomicI64,
    cancel: CancellationToken,
    /// backpressure: one permit per queued chunk slot. The task awaits a
    /// permit before buffering; the Lisp reader returns one per chunk taken.
    chunk_permits: Arc<tokio::sync::Semaphore>,
}

impl Shared {
    fn settle(&self, err: Option<HttpError>) {
        {
            let mut st = self.st.lock().unwrap();
            if !st.settled {
                st.settled = true;
                if st.err.is_none() {
                    st.err = err;
                }
            }
        }
        self.cv.notify_all();
    }
}

/// Runs on task teardown for EVERY exit path, including a dropped future.
struct TaskGuard {
    sh: Arc<Shared>,
    client: Arc<ClientInner>,
}

impl Drop for TaskGuard {
    fn drop(&mut self) {
        let cancelled = self.sh.cancel.is_cancelled();
        self.sh.settle(if cancelled {
            Some(HttpError::new("cancelled", "request cancelled"))
        } else {
            None
        });
        self.client.in_flight.fetch_sub(1, Ordering::SeqCst);
        self.client.admission.add_permits(1);
        self.client.ready.push(self.sh.id);
    }
}

// ---------------------------------------------------------------------------
// Ready queue: ids of requests that have settled since you last looked.
// ---------------------------------------------------------------------------

#[derive(Default)]
struct ReadyQ {
    ids: Mutex<VecDeque<u64>>,
    cv: Condvar,
}

impl ReadyQ {
    fn push(&self, id: u64) {
        self.ids.lock().unwrap().push_back(id);
        self.cv.notify_all();
    }

    fn pop(&self, wait_ms: u64) -> Option<u64> {
        let mut q = self.ids.lock().unwrap();
        if q.is_empty() {
            let (g, _) = self.cv.wait_timeout(q, capped(wait_ms)).unwrap();
            q = g;
        }
        q.pop_front()
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

struct ClientInner {
    rt: Mutex<Option<Runtime>>,
    http: reqwest::Client,
    admission: Arc<tokio::sync::Semaphore>,
    in_flight: AtomicU64,
    down: AtomicBool,
    next_id: AtomicU64,
    ready: ReadyQ,
    /// parent of every request token: cancelling it cancels all in flight
    cancel_all: CancellationToken,
    queue_chunks: usize,
    stall: Duration,
}

impl ClientInner {
    fn check_up(&self) -> Result<(), HttpError> {
        if self.down.load(Ordering::SeqCst) {
            return Err(HttpError::usage("client is shut down"));
        }
        Ok(())
    }
}

#[rulisp::handle]
pub struct Client {
    inner: Arc<ClientInner>,
}

impl Drop for Client {
    fn drop(&mut self) {
        // rulisp:free or the GC finalizer: cancel everything and let the
        // runtime wind down off-thread. Never block a finalizer.
        self.inner.down.store(true, Ordering::SeqCst);
        self.inner.cancel_all.cancel();
        if let Some(rt) = self.inner.rt.lock().unwrap().take() {
            rt.shutdown_background();
        }
    }
}

#[rulisp::export]
impl Client {
    /// (fetch:make-client 2 16 8 2000) — worker threads, max concurrent
    /// requests, buffered chunks per request, and the stall timeout in ms
    /// (how long the transfer may sit with a full buffer before failing).
    #[rulisp(constructor)]
    pub fn new(
        worker_threads: u64,
        max_in_flight: u64,
        queue_chunks: u64,
        stall_ms: u64,
    ) -> Result<Client, HttpError> {
        let workers = worker_threads.clamp(1, 64) as usize;
        let rt = Builder::new_multi_thread()
            .worker_threads(workers)
            .thread_name("rulisp-fetch")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        // build the client inside runtime context (no wait, no block_on)
        let http = {
            let _guard = rt.enter();
            reqwest::Client::builder()
                .user_agent("rulisp-fetch/0.1")
                .build()
                .map_err(|e| HttpError::new("runtime", e.to_string()))?
        };
        Ok(Client {
            inner: Arc::new(ClientInner {
                rt: Mutex::new(Some(rt)),
                http,
                admission: Arc::new(tokio::sync::Semaphore::new(
                    max_in_flight.clamp(1, 4096) as usize,
                )),
                in_flight: AtomicU64::new(0),
                down: AtomicBool::new(false),
                next_id: AtomicU64::new(1),
                ready: ReadyQ::default(),
                cancel_all: CancellationToken::new(),
                queue_chunks: queue_chunks.clamp(1, 4096) as usize,
                stall: Duration::from_millis(if stall_ms == 0 { 30_000 } else { stall_ms }),
            }),
        })
    }

    /// Id of a request that has settled, or NIL. Waits at most WAIT_CAP_MS.
    pub fn next_ready(&self, wait_ms: u64) -> Result<Option<u64>, HttpError> {
        refuse_reentry()?;
        Ok(self.inner.ready.pop(wait_ms))
    }

    pub fn in_flight(&self) -> u64 {
        self.inner.in_flight.load(Ordering::SeqCst)
    }

    pub fn is_down(&self) -> bool {
        self.inner.down.load(Ordering::SeqCst)
    }

    /// Cancel everything and stop the runtime. Idempotent. GRACE_MS is
    /// capped like every other wait, so this cannot wedge the image; the
    /// runtime finishes winding down in the background either way.
    pub fn shutdown(&self, grace_ms: u64) -> Result<(), HttpError> {
        refuse_reentry()?;
        self.inner.down.store(true, Ordering::SeqCst);
        self.inner.cancel_all.cancel();
        let rt = self.inner.rt.lock().unwrap().take();
        if let Some(rt) = rt {
            rt.shutdown_timeout(capped(grace_ms));
        }
        Ok(())
    }

    /// Start the hermetic loopback test server; returns its base URL. The
    /// socket is bound synchronously, so this waits for nothing.
    pub fn start_test_server(&self) -> Result<String, HttpError> {
        self.inner.check_up()?;
        let listener = std::net::TcpListener::bind("127.0.0.1:0")
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        listener
            .set_nonblocking(true)
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        let addr = listener
            .local_addr()
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        let guard = self.inner.rt.lock().unwrap();
        let rt = guard
            .as_ref()
            .ok_or_else(|| HttpError::usage("client is shut down"))?;
        let _enter = rt.enter();
        rt.spawn(async move {
            match tokio::net::TcpListener::from_std(listener) {
                Ok(l) => testserver::serve_loop(l).await,
                Err(_) => (),
            }
        });
        Ok(format!("http://{addr}"))
    }
}

// ---------------------------------------------------------------------------
// Req
// ---------------------------------------------------------------------------

#[rulisp::handle]
pub struct Req {
    sh: Arc<Shared>,
}

impl Drop for Req {
    fn drop(&mut self) {
        // Abandoning a request cancels it: the task stops, TaskGuard runs,
        // the permit comes back. This is why cancellation needs no core
        // feature — Drop is the cancellation path.
        self.sh.cancel.cancel();
        self.sh.cv.notify_all();
    }
}

#[rulisp::export]
impl Req {
    /// (fetch:make-req client "GET" url headers body sink-path timeout-ms
    ///                 max-body-bytes)
    /// HEADERS and BODY may be NIL. SINK-PATH streams the body straight to
    /// a file, so it never touches the Lisp heap. MAX-BODY-BYTES = 0 means
    /// unlimited; it is enforced against bytes RECEIVED, not against a
    /// Content-Length a hostile peer can omit.
    #[rulisp(constructor)]
    #[allow(clippy::too_many_arguments)]
    pub fn start(
        client: &Client,
        method: &str,
        url: &str,
        headers: Option<&[u8]>,
        body: Option<&[u8]>,
        sink_path: Option<&str>,
        timeout_ms: u64,
        max_body_bytes: u64,
    ) -> Result<Req, HttpError> {
        let inner = client.inner.clone();
        inner.check_up()?;

        let method = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|e| HttpError::request(format!("bad method: {e}")))?;
        let url = reqwest::Url::parse(url)
            .map_err(|e| HttpError::request(format!("bad url: {e}")))?;
        let hmap = match headers {
            Some(block) => decode_headers(block)?,
            None => HeaderMap::new(),
        };
        let body = body.map(|b| b.to_vec());
        let sink = sink_path.map(|s| s.to_string());

        // Admission control: refuse loudly rather than queue without bound.
        let permit = inner
            .admission
            .clone()
            .try_acquire_owned()
            .map_err(|_| HttpError::busy("too many requests in flight"))?;
        permit.forget(); // TaskGuard returns it

        let id = inner.next_id.fetch_add(1, Ordering::SeqCst);
        let sh = Arc::new(Shared {
            id,
            st: Mutex::new(State {
                settled: false,
                err: None,
                status: 0,
                headers: Vec::new(),
                head_done: false,
                chunks: VecDeque::new(),
                buffered: 0,
                eof: false,
            }),
            cv: Condvar::new(),
            received: AtomicU64::new(0),
            total: AtomicI64::new(-1),
            cancel: inner.cancel_all.child_token(),
            chunk_permits: Arc::new(tokio::sync::Semaphore::new(inner.queue_chunks)),
        });

        let guard = {
            let g = inner.rt.lock().unwrap();
            let rt = g
                .as_ref()
                .ok_or_else(|| HttpError::usage("client is shut down"))?;
            inner.in_flight.fetch_add(1, Ordering::SeqCst);
            let task_guard = TaskGuard {
                sh: sh.clone(),
                client: inner.clone(),
            };
            let sh2 = sh.clone();
            let http = inner.http.clone();
            let stall = inner.stall;
            rt.spawn(async move {
                let _g = task_guard; // terminal state on every exit path
                let work = run_request(
                    sh2.clone(),
                    http,
                    method,
                    url,
                    hmap,
                    body,
                    sink,
                    timeout_ms,
                    max_body_bytes,
                    stall,
                );
                tokio::select! {
                    biased;
                    _ = sh2.cancel.cancelled() => {}
                    r = work => {
                        if let Err(e) = r { sh2.settle(Some(e)); }
                    }
                }
            });
            Ok::<(), HttpError>(())
        };
        guard?;
        Ok(Req { sh })
    }

    pub fn id(&self) -> u64 {
        self.sh.id
    }

    /// The task has finished; buffered bytes may still be waiting.
    pub fn settled(&self) -> bool {
        self.sh.st.lock().unwrap().settled
    }

    /// Nothing more will ever come out: settled AND drained. This is the
    /// loop terminator.
    pub fn done(&self) -> bool {
        let st = self.sh.st.lock().unwrap();
        st.settled && st.chunks.is_empty()
    }

    pub fn failed(&self) -> bool {
        self.sh.st.lock().unwrap().err.is_some()
    }

    pub fn error_kind(&self) -> Option<String> {
        self.sh
            .st
            .lock()
            .unwrap()
            .err
            .as_ref()
            .map(|e| e.kind.to_string())
    }

    pub fn error_message(&self) -> Option<String> {
        self.sh
            .st
            .lock()
            .unwrap()
            .err
            .as_ref()
            .map(|e| e.msg.clone())
    }

    /// 0 until the response head has arrived.
    pub fn status(&self) -> u16 {
        self.sh.st.lock().unwrap().status
    }

    pub fn head_done(&self) -> bool {
        self.sh.st.lock().unwrap().head_done
    }

    /// The response header block, verbatim: name ": " value CRLF, repeated.
    pub fn headers(&self) -> Vec<u8> {
        self.sh.st.lock().unwrap().headers.clone()
    }

    /// Convenience accessor. The raw block is authoritative — a value that
    /// is not UTF-8 comes back lossy here.
    pub fn header(&self, name: &str) -> Option<String> {
        let st = self.sh.st.lock().unwrap();
        let want = name.to_ascii_lowercase();
        for line in st.headers.split(|&b| b == b'\n') {
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            if let Some(c) = line.iter().position(|&b| b == b':') {
                let n = String::from_utf8_lossy(&line[..c]).to_ascii_lowercase();
                if n == want {
                    let v = &line[c + 1..];
                    let v = match v.iter().position(|&b| b != b' ') {
                        Some(i) => &v[i..],
                        None => &v[v.len()..],
                    };
                    return Some(String::from_utf8_lossy(v).into_owned());
                }
            }
        }
        None
    }

    pub fn received(&self) -> u64 {
        self.sh.received.load(Ordering::SeqCst)
    }

    /// Content-Length, or NIL when the server didn't send one.
    pub fn total(&self) -> Option<u64> {
        let t = self.sh.total.load(Ordering::SeqCst);
        if t < 0 {
            None
        } else {
            Some(t as u64)
        }
    }

    pub fn buffered(&self) -> u64 {
        self.sh.st.lock().unwrap().buffered
    }

    /// Pull up to MAX_BYTES of body. NIL means "nothing available right
    /// now" — check `req-done` to tell that from end-of-body. Waits at most
    /// WAIT_CAP_MS. Buffered bytes are always drained before an error
    /// surfaces.
    pub fn read(&self, max_bytes: u64, wait_ms: u64) -> Result<Option<Vec<u8>>, HttpError> {
        refuse_reentry()?;
        let max = if max_bytes == 0 {
            usize::MAX
        } else {
            max_bytes as usize
        };
        let mut st = self.sh.st.lock().unwrap();
        if st.chunks.is_empty() && !st.settled {
            let (g, _) = self.sh.cv.wait_timeout(st, capped(wait_ms)).unwrap();
            st = g;
        }
        if let Some(mut chunk) = st.chunks.pop_front() {
            let give_back = if chunk.len() > max {
                let rest = chunk.split_off(max);
                st.chunks.push_front(rest);
                false // slot still occupied by the remainder
            } else {
                true
            };
            st.buffered -= chunk.len() as u64;
            drop(st);
            if give_back {
                self.sh.chunk_permits.add_permits(1);
            }
            return Ok(Some(chunk));
        }
        if st.settled {
            if let Some(e) = &st.err {
                return Err(e.clone());
            }
            return Ok(None); // end of body
        }
        Ok(None) // not ready yet
    }

    /// Wait (at most WAIT_CAP_MS) for the request to settle; returns T if
    /// it has. Loop in Lisp.
    pub fn wait(&self, wait_ms: u64) -> Result<bool, HttpError> {
        refuse_reentry()?;
        let mut st = self.sh.st.lock().unwrap();
        if !st.settled {
            let (g, _) = self.sh.cv.wait_timeout(st, capped(wait_ms)).unwrap();
            st = g;
        }
        Ok(st.settled)
    }

    pub fn cancel(&self) {
        self.sh.cancel.cancel();
        self.sh.cv.notify_all();
    }
}

// ---------------------------------------------------------------------------
// The task
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn run_request(
    sh: Arc<Shared>,
    http: reqwest::Client,
    method: reqwest::Method,
    url: reqwest::Url,
    headers: HeaderMap,
    body: Option<Vec<u8>>,
    sink: Option<String>,
    timeout_ms: u64,
    max_body_bytes: u64,
    stall: Duration,
) -> Result<(), HttpError> {
    let mut rb = http.request(method, url).headers(headers);
    if timeout_ms > 0 {
        rb = rb.timeout(Duration::from_millis(timeout_ms));
    }
    if let Some(b) = body {
        rb = rb.body(b);
    }
    let resp = rb
        .send()
        .await
        .map_err(|e| HttpError::new(if e.is_timeout() { "timeout" } else { "transport" }, e.to_string()))?;

    {
        let mut st = sh.st.lock().unwrap();
        st.status = resp.status().as_u16();
        st.headers = encode_headers(resp.headers());
        st.head_done = true;
    }
    if let Some(len) = resp.content_length() {
        sh.total.store(len as i64, Ordering::SeqCst);
    }
    sh.cv.notify_all();

    let mut file = match &sink {
        Some(path) => Some(
            tokio::fs::File::create(path)
                .await
                .map_err(|e| HttpError::new("io", e.to_string()))?,
        ),
        None => None,
    };

    let mut stream = resp.bytes_stream();
    while let Some(item) = stream.next().await {
        let bytes = item.map_err(|e| {
            HttpError::new(if e.is_timeout() { "timeout" } else { "transport" }, e.to_string())
        })?;
        let n = bytes.len() as u64;
        let total = sh.received.fetch_add(n, Ordering::SeqCst) + n;
        if max_body_bytes > 0 && total > max_body_bytes {
            return Err(HttpError::new(
                "too-large",
                format!("body exceeded {max_body_bytes} bytes"),
            ));
        }
        match file.as_mut() {
            Some(f) => {
                f.write_all(&bytes)
                    .await
                    .map_err(|e| HttpError::new("io", e.to_string()))?;
            }
            None => {
                // Backpressure: wait for a free slot, but not forever — if
                // the Lisp side never drains, fail loudly instead of pinning
                // the socket until the request timeout.
                let permit = tokio::time::timeout(stall, sh.chunk_permits.clone().acquire_owned())
                    .await
                    .map_err(|_| {
                        HttpError::new("stalled", "reader did not drain the buffer in time")
                    })?
                    .map_err(|_| HttpError::new("runtime", "chunk semaphore closed"))?;
                permit.forget(); // returned by the reader
                let mut st = sh.st.lock().unwrap();
                st.buffered += n;
                st.chunks.push_back(bytes.to_vec());
                drop(st);
                sh.cv.notify_all();
            }
        }
    }
    if let Some(mut f) = file {
        f.flush()
            .await
            .map_err(|e| HttpError::new("io", e.to_string()))?;
    }
    sh.st.lock().unwrap().eof = true;
    sh.cv.notify_all();
    Ok(())
}

rulisp::module! {
    name: "fetch",
    handles: [Client, Req],
    fns: [
        Client::new, Client::next_ready, Client::in_flight, Client::is_down,
        Client::shutdown, Client::start_test_server,
        Req::start, Req::id, Req::settled, Req::done, Req::failed,
        Req::error_kind, Req::error_message, Req::status, Req::head_done,
        Req::headers, Req::header, Req::received, Req::total, Req::buffered,
        Req::read, Req::wait, Req::cancel,
    ],
}

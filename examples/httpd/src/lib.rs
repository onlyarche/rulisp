//! httpd: an HTTP server whose handlers are a Lisp pull loop — fetch's
//! mirror. Rust owns the listener, every connection and HTTP/1.1 + h2c on
//! tokio, and parks each request (its parts plus a oneshot for the
//! response) in a bounded queue; Lisp threads pull with a capped wait
//! (BOUNDARY §7) and answer through the `Request` handle. No stored
//! callback, no `block_on`, an `on_dump` hook that quiesces every server.
//!
//! The shape is dictated by the boundary: a stored callback returns no
//! value to Rust, so a Lisp handler cannot answer through a callback — it
//! pulls. See docs/design/v08-plan.md item 2.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, HeaderName, HeaderValue, Response, StatusCode};
use axum::Router;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{oneshot, Notify};

/// Every blocking export returns within this many milliseconds whatever
/// the caller asked for: a Lisp thread inside a foreign call cannot be
/// interrupted, so the loop belongs in Lisp (BOUNDARY §7).
const WAIT_CAP_MS: u64 = 100;

#[derive(Debug, Clone)]
pub struct HttpError {
    pub kind: &'static str,
    pub msg: String,
}
impl HttpError {
    fn new(kind: &'static str, msg: impl Into<String>) -> Self {
        HttpError { kind, msg: msg.into() }
    }
}
impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.kind, self.msg)
    }
}
impl std::error::Error for HttpError {}

fn refuse_reentry() -> Result<(), HttpError> {
    if tokio::runtime::Handle::try_current().is_ok() {
        return Err(HttpError::new("usage", "blocking export called from inside the runtime"));
    }
    Ok(())
}

/// fetch's header codec: `name: value\r\n` repeated, lossless (duplicates
/// and order survive; the Lisp side splits it).
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
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.is_empty() {
            continue;
        }
        let c = line
            .iter()
            .position(|&b| b == b':')
            .ok_or_else(|| HttpError::new("response", "header line without a colon"))?;
        let name = HeaderName::from_bytes(line[..c].trim_ascii())
            .map_err(|e| HttpError::new("response", format!("bad header name: {e}")))?;
        let value = HeaderValue::from_bytes(line[c + 1..].trim_ascii_start())
            .map_err(|e| HttpError::new("response", format!("bad header value: {e}")))?;
        map.append(name, value);
    }
    Ok(map)
}

fn status_only(code: u16) -> Response<Body> {
    Response::builder().status(code).body(Body::empty()).unwrap()
}

struct Parts {
    method: String,
    path: String,
    query: Option<String>,
    headers: Vec<u8>,
    body: Vec<u8>,
}

/// A request the service parked for Lisp, with its answer channel.
struct Parked {
    parts: Parts,
    reply: oneshot::Sender<Response<Body>>,
}

/// The bounded queue between the tokio tasks and the Lisp pullers. The
/// service never blocks on it (full → 503 at once); the Lisp side waits
/// on it at most WAIT_CAP_MS per call.
struct Svc {
    q: Mutex<VecDeque<Parked>>,
    cv: Condvar,
    cap: usize,
    body_cap: usize,
    down: AtomicBool,
    in_flight: AtomicU64,
}

impl Svc {
    fn push(&self, p: Parked) -> Result<(), Parked> {
        let mut q = self.q.lock().unwrap();
        if q.len() >= self.cap {
            return Err(p);
        }
        q.push_back(p);
        drop(q);
        self.cv.notify_one();
        Ok(())
    }
    /// True when a request is parked; waits at most min(wait_ms, cap).
    fn wait(&self, wait_ms: u64) -> bool {
        let mut q = self.q.lock().unwrap();
        if q.is_empty() {
            let (g, _) = self.cv.wait_timeout(q, Duration::from_millis(wait_ms.min(WAIT_CAP_MS))).unwrap();
            q = g;
        }
        !q.is_empty()
    }
    fn take(&self) -> Option<Parked> {
        self.q.lock().unwrap().pop_front()
    }
    /// Unpulled requests are answered 503 when the server stops.
    fn drain(&self) {
        let drained: Vec<Parked> = self.q.lock().unwrap().drain(..).collect();
        for p in drained {
            let _ = p.reply.send(status_only(503));
        }
    }
}

async fn park(State(svc): State<Arc<Svc>>, req: axum::extract::Request) -> Response<Body> {
    if svc.down.load(SeqCst) {
        return status_only(503);
    }
    let (parts, body) = req.into_parts();
    let body = match axum::body::to_bytes(body, svc.body_cap).await {
        Ok(b) => b.to_vec(),
        Err(_) => return status_only(413),
    };
    let (tx, rx) = oneshot::channel();
    let parked = Parked {
        parts: Parts {
            method: parts.method.to_string(),
            path: parts.uri.path().to_string(),
            query: parts.uri.query().map(str::to_string),
            headers: encode_headers(&parts.headers),
            body,
        },
        reply: tx,
    };
    if svc.push(parked).is_err() {
        return status_only(503); // queue full: backpressure, immediately
    }
    // Err: the Parked was dropped before Lisp pulled it (stop/free drained it)
    rx.await.unwrap_or_else(|_| status_only(503))
}

struct ServerInner {
    rt: Mutex<Option<Runtime>>,
    svc: Arc<Svc>,
    port: u16,
    stop: Arc<Notify>,
    finished: Arc<(Mutex<bool>, Condvar)>,
}

impl ServerInner {
    /// Graceful first (the 503s for unpulled requests get written), then
    /// the runtime goes down; GRACE bounds the whole thing.
    fn quiesce(&self, grace: Duration) {
        self.svc.down.store(true, SeqCst);
        self.stop.notify_one();
        self.svc.drain();
        let started = std::time::Instant::now();
        let (lock, cv) = &*self.finished;
        let mut done = lock.lock().unwrap();
        while !*done && started.elapsed() < grace {
            done = cv.wait_timeout(done, grace - started.elapsed()).unwrap().0;
        }
        drop(done);
        if let Some(rt) = self.rt.lock().unwrap().take() {
            rt.shutdown_timeout(grace.saturating_sub(started.elapsed()));
        }
    }
}

/// Every live server, for the dump hook (fetch's CLIENTS).
static SERVERS: Mutex<Vec<Weak<ServerInner>>> = Mutex::new(Vec::new());

/// An HTTP server whose handlers are a Lisp pull loop: `server-wait`,
/// `take-request`, `request-respond`. Stop it in order — `server-stop`,
/// poll `server-stopped`, `server-shutdown` — before `rulisp:free`; a free
/// with clients connected resets them (Drop cannot block).
#[rulisp::handle]
pub struct Server {
    inner: Arc<ServerInner>,
}

impl Drop for Server {
    fn drop(&mut self) {
        // rulisp:free or the finalizer: never block here
        self.inner.svc.down.store(true, SeqCst);
        self.inner.stop.notify_one();
        self.inner.svc.drain();
        if let Some(rt) = self.inner.rt.lock().unwrap().take() {
            rt.shutdown_background();
        }
    }
}

#[rulisp::export]
impl Server {
    /// (httpd:make-server "127.0.0.1:0" 8 2 1048576): bind ADDR (port 0
    /// picks a free one — `server-port` tells which), park at most QUEUE
    /// requests (more are answered 503 at once), run WORKERS tokio threads,
    /// and read at most BODY-CAP bytes of a request body (more is 413).
    #[rulisp(constructor)]
    pub fn bind(addr: &str, queue: u64, workers: u64, body_cap: u64) -> Result<Server, HttpError> {
        let io = |e: std::io::Error| HttpError::new("runtime", e.to_string());
        let listener = std::net::TcpListener::bind(addr).map_err(io)?;
        listener.set_nonblocking(true).map_err(io)?;
        let port = listener.local_addr().map_err(io)?.port();
        let rt = Builder::new_multi_thread()
            .worker_threads(workers.clamp(1, 64) as usize)
            .thread_name("rulisp-httpd")
            .enable_io()
            .enable_time()
            .build()
            .map_err(io)?;
        let svc = Arc::new(Svc {
            q: Mutex::new(VecDeque::new()),
            cv: Condvar::new(),
            cap: queue.clamp(1, 65536) as usize,
            body_cap: body_cap.clamp(1 << 10, 1 << 30) as usize,
            down: AtomicBool::new(false),
            in_flight: AtomicU64::new(0),
        });
        let stop = Arc::new(Notify::new());
        let finished = Arc::new((Mutex::new(false), Condvar::new()));
        {
            let _enter = rt.enter();
            let listener = tokio::net::TcpListener::from_std(listener).map_err(io)?;
            let app = Router::new().fallback(park).with_state(svc.clone());
            let (stop, finished) = (stop.clone(), finished.clone());
            rt.spawn(async move {
                let _ = axum::serve(listener, app)
                    .with_graceful_shutdown(async move { stop.notified().await })
                    .await;
                *finished.0.lock().unwrap() = true;
                finished.1.notify_all();
            });
        }
        let inner = Arc::new(ServerInner { rt: Mutex::new(Some(rt)), svc, port, stop, finished });
        let mut reg = SERVERS.lock().unwrap();
        reg.retain(|w| w.strong_count() > 0);
        reg.push(Arc::downgrade(&inner));
        Ok(Server { inner })
    }

    /// The bound port (what port 0 picked).
    pub fn port(&self) -> u64 {
        self.inner.port as u64
    }

    /// Requests parked and not yet pulled.
    pub fn pending(&self) -> u64 {
        self.inner.svc.q.lock().unwrap().len() as u64
    }

    /// Requests pulled by Lisp and not yet answered.
    pub fn in_flight(&self) -> u64 {
        self.inner.svc.in_flight.load(SeqCst)
    }

    /// T once `server-stop`, `server-shutdown` or the dump hook ran.
    pub fn is_down(&self) -> bool {
        self.inner.svc.down.load(SeqCst)
    }

    /// (httpd:server-wait s 100): T when a request is parked, NIL on an
    /// idle tick — never a condition when idle. Waits at most 100 ms
    /// whatever WAIT-MS says; the loop belongs in Lisp.
    pub fn wait(&self, wait_ms: u64) -> Result<bool, HttpError> {
        refuse_reentry()?;
        if self.inner.svc.down.load(SeqCst) {
            return Err(HttpError::new("usage", "server is stopped"));
        }
        Ok(self.inner.svc.wait(wait_ms))
    }

    /// Graceful: stop accepting, answer unpulled requests 503, let pulled
    /// ones finish. Returns at once; poll `server-stopped` from Lisp.
    pub fn stop(&self) {
        self.inner.svc.down.store(true, SeqCst);
        self.inner.stop.notify_one();
        self.inner.svc.drain();
    }

    /// T once every connection has closed. Waits at most 100 ms.
    pub fn stopped(&self, wait_ms: u64) -> Result<bool, HttpError> {
        refuse_reentry()?;
        let (lock, cv) = &*self.inner.finished;
        let mut done = lock.lock().unwrap();
        if !*done {
            let (g, _) = cv.wait_timeout(done, Duration::from_millis(wait_ms.min(WAIT_CAP_MS))).unwrap();
            done = g;
        }
        Ok(*done)
    }

    /// Tear the runtime down — fetch's one bounded exception to the wait
    /// cap, GRACE-MS at most 5 s.
    pub fn shutdown(&self, grace_ms: u64) -> Result<(), HttpError> {
        refuse_reentry()?;
        self.inner.quiesce(Duration::from_millis(grace_ms.min(5_000)));
        Ok(())
    }
}

/// One parked HTTP request. Answer it with `request-respond` exactly
/// once; a request freed unanswered answers 500 — when the handle is
/// freed, not when the GC gets to it, so free it in `unwind-protect`.
#[rulisp::handle]
pub struct Request {
    p: Parts,
    reply: Mutex<Option<oneshot::Sender<Response<Body>>>>,
    svc: Arc<Svc>,
}

impl Drop for Request {
    fn drop(&mut self) {
        // pulled but never answered (free, GC, or an unwound handler): 500
        if let Some(tx) = self.reply.lock().unwrap().take() {
            let _ = tx.send(status_only(500));
            self.svc.in_flight.fetch_sub(1, SeqCst);
        }
    }
}

#[rulisp::export]
impl Request {
    /// (httpd:take-request s): the next parked request, now. Signals
    /// `httpd:http-error` kind "empty" when none is parked (racing pullers
    /// took it — wait again) and "usage" once the server is stopped.
    #[rulisp(constructor, name = "take-request")]
    pub fn take(server: &Server) -> Result<Request, HttpError> {
        let svc = server.inner.svc.clone();
        if svc.down.load(SeqCst) {
            return Err(HttpError::new("usage", "server is stopped"));
        }
        let Parked { parts, reply } =
            svc.take().ok_or_else(|| HttpError::new("empty", "no request parked"))?;
        svc.in_flight.fetch_add(1, SeqCst);
        Ok(Request { p: parts, reply: Mutex::new(Some(reply)), svc })
    }

    /// "GET", "POST", …
    pub fn method(&self) -> String {
        self.p.method.clone()
    }
    /// The path, percent-encoded as it arrived.
    pub fn path(&self) -> String {
        self.p.path.clone()
    }
    /// The query string without the "?", or NIL.
    pub fn query(&self) -> Option<String> {
        self.p.query.clone()
    }
    /// The request header block: `name: value` CRLF, repeated, in wire
    /// order with duplicates (fetch's codec).
    pub fn headers(&self) -> Vec<u8> {
        self.p.headers.clone()
    }
    /// The whole body (at most the server's BODY-CAP).
    pub fn body(&self) -> Vec<u8> {
        self.p.body.clone()
    }
    /// NIL once the client gave up waiting (its connection closed).
    pub fn alive(&self) -> bool {
        self.reply.lock().unwrap().as_ref().is_some_and(|tx| !tx.is_closed())
    }

    /// (httpd:request-respond r 200 nil body): answer once. HEADERS is a
    /// CRLF block or NIL. Kind "usage" on a second call, "gone" when the
    /// client already went away, "response" for a bad status or block.
    pub fn respond(&self, status: u16, headers: Option<&[u8]>, body: &[u8]) -> Result<(), HttpError> {
        let tx = self
            .reply
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| HttpError::new("usage", "request already answered"))?;
        self.svc.in_flight.fetch_sub(1, SeqCst);
        let mut b = Response::builder().status(
            StatusCode::from_u16(status).map_err(|e| HttpError::new("response", e.to_string()))?,
        );
        if let Some(h) = headers {
            *b.headers_mut().unwrap() = decode_headers(h)?;
        }
        let resp = b.body(Body::from(body.to_vec())).map_err(|e| HttpError::new("response", e.to_string()))?;
        tx.send(resp).map_err(|_| HttpError::new("gone", "client went away"))
    }
}

/// The declared dump hook: quiesce every live server, 2 s each at most
/// (BOUNDARY §10). Stop your pullers first — SBCL refuses to dump with
/// Lisp threads running; this hook covers the Rust threads.
#[rulisp::export]
pub fn shutdown_all() {
    let live: Vec<Arc<ServerInner>> = SERVERS.lock().unwrap().iter().filter_map(Weak::upgrade).collect();
    for s in live {
        s.quiesce(Duration::from_millis(2_000));
    }
}

rulisp::module! {
    name: "httpd",
    handles: [Server, Request],
    fns: [
        Server::bind, Server::port, Server::pending, Server::in_flight, Server::is_down,
        Server::wait, Server::stop, Server::stopped, Server::shutdown,
        Request::take, Request::method, Request::path, Request::query, Request::headers,
        Request::body, Request::alive, Request::respond,
        shutdown_all,
    ],
    on_dump: shutdown_all,
}

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
//!
//! Every bound a server cannot ship without is here, not in a later
//! commit: a timer on every connection (a half-sent request line or an
//! idle keep-alive closes at HEAD-MS), a body size and a body time, a
//! connection cap held as a semaphore permit per accept, a queue that
//! waits QUEUE-WAIT-MS for a slot before 503, dead slots pruned, a
//! HANDLER-MS after which an unanswered request is 504, and a dump hook
//! whose drain is bounded. What stays unbounded is stated in SECURITY.md.

use std::collections::{HashMap, VecDeque};
use std::convert::Infallible;
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::http::header::{CONTENT_LENGTH, RETRY_AFTER};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Request as HttpRequest, Response, StatusCode};
use axum::Router;
use hyper::body::Incoming;
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto;
use hyper_util::server::graceful::GracefulShutdown;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{oneshot, Notify, Semaphore};
use tokio_util::io::ReaderStream;

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
    fn io(e: std::io::Error) -> Self {
        HttpError::new("io", e.to_string())
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

fn capped(wait_ms: u64) -> Duration {
    Duration::from_millis(wait_ms.min(WAIT_CAP_MS))
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

/// The block must be CRLF-separated: a bare LF means the caller built it
/// by hand and wrongly, and a CR or LF inside a value is request splitting
/// — `HeaderValue` refuses both.
fn decode_headers(block: &[u8]) -> Result<HeaderMap, HttpError> {
    let mut map = HeaderMap::new();
    let mut rest = block;
    while !rest.is_empty() {
        let nl = rest.iter().position(|&b| b == b'\n').unwrap_or(rest.len());
        let (line, tail) = rest.split_at(nl);
        rest = if tail.is_empty() { tail } else { &tail[1..] };
        let line = match line.strip_suffix(b"\r") {
            Some(l) => l,
            None if !tail.is_empty() => return Err(HttpError::new("response", "header block is not CRLF-separated")),
            None => line,
        };
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
    version: String,
    peer: String,
    headers: HeaderMap,
    body: Vec<u8>,
}

/// A request the service parked for Lisp, with its answer channel.
struct Parked {
    parts: Parts,
    reply: oneshot::Sender<Response<Body>>,
}

/// The bounded queue between the tokio tasks and the Lisp pullers, and
/// the limits the constructor fixed. The service waits for a slot at most
/// QUEUE-WAIT (an async wait, inside tokio); the Lisp side waits on it at
/// most WAIT_CAP_MS per call.
struct Svc {
    q: Mutex<VecDeque<Parked>>,
    cv: Condvar,
    slot_freed: Notify,
    cap: usize,
    body_cap: usize,
    body_wait: Duration,
    queue_wait: Duration,
    handler_wait: Option<Duration>,
    head_wait: Duration,
    max_connections: usize,
    connections: AtomicU64,
    down: AtomicBool,
    in_flight: AtomicU64,
}

impl Svc {
    /// Prune entries whose client left (their oneshot receiver is gone),
    /// so a stall cannot turn into a 503 storm for live clients later.
    fn prune(q: &mut VecDeque<Parked>) -> bool {
        let before = q.len();
        q.retain(|p| !p.reply.is_closed());
        q.len() != before
    }

    async fn push(&self, p: Parked) -> Result<(), Parked> {
        let deadline = Instant::now() + self.queue_wait;
        loop {
            // enable before checking, so a slot freed between the check
            // and the await is not missed
            let notified = self.slot_freed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut q = self.q.lock().unwrap();
                Self::prune(&mut q);
                if q.len() < self.cap {
                    q.push_back(p);
                    drop(q);
                    self.cv.notify_one();
                    return Ok(());
                }
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(p);
            }
            let _ = tokio::time::timeout(deadline - now, notified).await;
        }
    }

    /// True when a live request is parked; waits at most min(wait_ms, cap).
    fn wait(&self, wait_ms: u64) -> bool {
        let mut q = self.q.lock().unwrap();
        if Self::prune(&mut q) {
            self.slot_freed.notify_waiters();
        }
        if q.is_empty() {
            let (g, _) = self.cv.wait_timeout(q, capped(wait_ms)).unwrap();
            q = g;
        }
        !q.is_empty()
    }

    fn take(&self) -> Option<Parked> {
        let mut q = self.q.lock().unwrap();
        let freed = Self::prune(&mut q);
        let p = q.pop_front();
        drop(q);
        if freed || p.is_some() {
            self.slot_freed.notify_waiters();
        }
        p
    }

    /// Unpulled requests are answered 503 when the server stops.
    fn drain(&self) {
        let drained: Vec<Parked> = self.q.lock().unwrap().drain(..).collect();
        for p in drained {
            let _ = p.reply.send(status_only(503));
        }
        self.slot_freed.notify_waiters();
    }
}

/// The accept loop stamps each connection's peer into its requests.
#[derive(Clone, Copy)]
struct Peer(SocketAddr);

async fn park(State(svc): State<Arc<Svc>>, req: axum::extract::Request) -> Response<Body> {
    if svc.down.load(SeqCst) {
        return status_only(503);
    }
    let (parts, body) = req.into_parts();
    // the whole body is read here, under BODY-CAP and BODY-MS, before the
    // request is parked: a slow or oversized body never reaches Lisp.
    // (A client that resets mid-body also lands in the 413 arm; nobody
    // is left to read that status.)
    let body = match tokio::time::timeout(svc.body_wait, axum::body::to_bytes(body, svc.body_cap)).await {
        Err(_) => return status_only(408),
        Ok(Err(_)) => return status_only(413),
        Ok(Ok(b)) => b.to_vec(),
    };
    let (tx, rx) = oneshot::channel();
    let parked = Parked {
        parts: Parts {
            method: parts.method.to_string(),
            path: parts.uri.path().to_string(),
            query: parts.uri.query().map(str::to_string),
            version: format!("{:?}", parts.version),
            peer: parts.extensions.get::<Peer>().map(|p| p.0.to_string()).unwrap_or_default(),
            headers: parts.headers,
            body,
        },
        reply: tx,
    };
    if svc.push(parked).await.is_err() {
        // no slot within QUEUE-WAIT: backpressure, and the client may retry
        let mut r = status_only(503);
        r.headers_mut().insert(RETRY_AFTER, HeaderValue::from_static("1"));
        return r;
    }
    // Err: the Parked was dropped before Lisp answered (stop drained it, or
    // the entry was pruned after this client left)
    match svc.handler_wait {
        None => rx.await.unwrap_or_else(|_| status_only(503)),
        Some(limit) => match tokio::time::timeout(limit, rx).await {
            Ok(r) => r.unwrap_or_else(|_| status_only(503)),
            Err(_) => status_only(504), // Lisp did not answer in time; its later respond is "gone"
        },
    }
}

/// The hyper service for one connection: the Router, with the peer
/// address stamped into every request before axum sees it.
#[derive(Clone)]
struct WithPeer {
    app: Router,
    peer: SocketAddr,
}

impl hyper::service::Service<HttpRequest<Incoming>> for WithPeer {
    type Response = Response<Body>;
    type Error = Infallible;
    type Future = Pin<Box<dyn Future<Output = Result<Response<Body>, Infallible>> + Send>>;

    fn call(&self, req: HttpRequest<Incoming>) -> Self::Future {
        let mut req = req.map(Body::new);
        req.extensions_mut().insert(Peer(self.peer));
        let mut app = self.app.clone();
        Box::pin(async move { tower_service::Service::call(&mut app, req).await })
    }
}

/// Our own loop instead of `axum::serve`: a timer on every connection and
/// a permit per connection. The N+1th client waits in the kernel backlog
/// with no descriptor opened in this process.
async fn accept_loop(
    listener: tokio::net::TcpListener,
    app: Router,
    svc: Arc<Svc>,
    stop: Arc<Notify>,
    finished: Arc<(Mutex<bool>, Condvar)>,
) {
    let graceful = GracefulShutdown::new();
    let sem = Arc::new(Semaphore::new(svc.max_connections));
    let mut builder = auto::Builder::new(TokioExecutor::new());
    builder
        .http1()
        .timer(TokioTimer::new())
        .header_read_timeout(svc.head_wait)
        .http2()
        .timer(TokioTimer::new());
    loop {
        let permit = tokio::select! {
            _ = stop.notified() => break,
            p = sem.clone().acquire_owned() => match p {
                Ok(p) => p,
                Err(_) => break,
            },
        };
        let (stream, peer) = tokio::select! {
            _ = stop.notified() => break,
            r = listener.accept() => match r {
                Ok(x) => x,
                Err(_) => {
                    // EMFILE and friends: back off instead of spinning
                    tokio::time::sleep(Duration::from_millis(10)).await;
                    continue;
                }
            },
        };
        svc.connections.fetch_add(1, SeqCst);
        let conn = builder
            .serve_connection(TokioIo::new(stream), WithPeer { app: app.clone(), peer })
            .into_owned();
        let conn = graceful.watch(conn);
        let svc = svc.clone();
        tokio::spawn(async move {
            let _ = conn.await;
            svc.connections.fetch_sub(1, SeqCst);
            drop(permit);
        });
    }
    drop(listener); // the port closes here
    graceful.shutdown().await; // pulled requests finish; idle connections close
    *finished.0.lock().unwrap() = true;
    finished.1.notify_all();
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
        let started = Instant::now();
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

/// Every live server and probe, for the dump hook (fetch's CLIENTS).
static SERVERS: Mutex<Vec<Weak<ServerInner>>> = Mutex::new(Vec::new());
static PROBES: Mutex<Vec<Weak<ProbeInner>>> = Mutex::new(Vec::new());

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
    /// (httpd:make-server "127.0.0.1:0" 256 2 512 1048576 10000 10000 1000 0):
    /// bind ADDR (port 0 picks a free one — `server-port` tells which);
    /// park at most QUEUE requests; run WORKERS tokio threads; keep at
    /// most MAX-CONNECTIONS open (the next waits in the kernel backlog);
    /// read at most BODY-CAP bytes of a body (more is 413); allow HEAD-MS
    /// to read a request head — also the idle keep-alive bound — and
    /// BODY-MS to read a body (408); let a request wait QUEUE-WAIT-MS for
    /// a free slot before 503 with Retry-After; answer 504 when Lisp has
    /// not responded HANDLER-MS after the request was parked (0 = never:
    /// the REPL default, where a debugger session may hold its client).
    #[rulisp(constructor)]
    #[allow(clippy::too_many_arguments)]
    pub fn bind(
        addr: &str,
        queue: u64,
        workers: u64,
        max_connections: u64,
        body_cap: u64,
        head_ms: u64,
        body_ms: u64,
        queue_wait_ms: u64,
        handler_ms: u64,
    ) -> Result<Server, HttpError> {
        let listener = std::net::TcpListener::bind(addr).map_err(HttpError::io)?;
        listener.set_nonblocking(true).map_err(HttpError::io)?;
        let port = listener.local_addr().map_err(HttpError::io)?.port();
        let rt = Builder::new_multi_thread()
            .worker_threads(workers.clamp(1, 64) as usize)
            .max_blocking_threads(8) // respond-file reads through tokio::fs
            .thread_name("rulisp-httpd")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        let svc = Arc::new(Svc {
            q: Mutex::new(VecDeque::new()),
            cv: Condvar::new(),
            slot_freed: Notify::new(),
            cap: queue.clamp(1, 65536) as usize,
            body_cap: body_cap.clamp(1 << 10, 1 << 30) as usize,
            body_wait: Duration::from_millis(body_ms.clamp(1, 3_600_000)),
            queue_wait: Duration::from_millis(queue_wait_ms.min(3_600_000)),
            handler_wait: (handler_ms > 0).then(|| Duration::from_millis(handler_ms)),
            head_wait: Duration::from_millis(head_ms.clamp(1, 3_600_000)),
            max_connections: max_connections.clamp(1, 1 << 20) as usize,
            connections: AtomicU64::new(0),
            down: AtomicBool::new(false),
            in_flight: AtomicU64::new(0),
        });
        let stop = Arc::new(Notify::new());
        let finished = Arc::new((Mutex::new(false), Condvar::new()));
        {
            let _enter = rt.enter();
            let listener = tokio::net::TcpListener::from_std(listener).map_err(HttpError::io)?;
            let app = Router::new().fallback(park).with_state(svc.clone());
            rt.spawn(accept_loop(listener, app, svc.clone(), stop.clone(), finished.clone()));
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

    /// Connections open right now (at most MAX-CONNECTIONS).
    pub fn connections(&self) -> u64 {
        self.inner.svc.connections.load(SeqCst)
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

    /// Graceful: stop accepting (the port closes), answer unpulled
    /// requests 503, let pulled ones finish. Returns at once; poll
    /// `server-stopped` from Lisp.
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
            let (g, _) = cv.wait_timeout(done, capped(wait_ms)).unwrap();
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

/// One parked HTTP request. Answer it with `request-respond` or
/// `request-respond-file` exactly once; a request freed unanswered answers
/// 500 — when the handle is freed, not when the GC gets to it, so free it
/// in `unwind-protect`.
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

impl Request {
    /// Build the whole response before the reply channel is taken, so a
    /// bad status or header block leaves the request answerable.
    fn send(&self, resp: Response<Body>) -> Result<(), HttpError> {
        let tx = self
            .reply
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| HttpError::new("usage", "request already answered"))?;
        self.svc.in_flight.fetch_sub(1, SeqCst);
        tx.send(resp).map_err(|_| HttpError::new("gone", "client went away"))
    }

    fn builder(status: u16, headers: Option<&[u8]>) -> Result<axum::http::response::Builder, HttpError> {
        let code = StatusCode::from_u16(status).map_err(|e| HttpError::new("response", e.to_string()))?;
        let mut b = Response::builder().status(code);
        if let Some(h) = headers {
            *b.headers_mut().unwrap() = decode_headers(h)?;
        }
        Ok(b)
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
    /// "HTTP/1.1" or "HTTP/2.0".
    pub fn version(&self) -> String {
        self.p.version.clone()
    }
    /// The client's address, "ip:port".
    pub fn peer(&self) -> String {
        self.p.peer.clone()
    }
    /// The request header block: `name: value` CRLF, repeated (fetch's
    /// codec). Lossless for a name's values — duplicates stay, in order —
    /// while names are grouped as hyper's header map keeps them.
    pub fn headers(&self) -> Vec<u8> {
        encode_headers(&self.p.headers)
    }
    /// The first value of header NAME (case-insensitive), or NIL — the
    /// lossy convenience; `request-headers` has them all.
    pub fn header(&self, name: &str) -> Option<String> {
        self.p.headers.get(name).map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned())
    }
    /// The whole body (at most the server's BODY-CAP).
    pub fn body(&self) -> Vec<u8> {
        self.p.body.clone()
    }
    /// NIL once the client gave up waiting (its connection closed, or
    /// HANDLER-MS answered it 504).
    pub fn alive(&self) -> bool {
        self.reply.lock().unwrap().as_ref().is_some_and(|tx| !tx.is_closed())
    }

    /// (httpd:request-respond r 200 nil body): answer once. HEADERS is a
    /// CRLF block or NIL. Kind "usage" on a second call, "gone" when the
    /// client already went away, "response" for a bad status or block —
    /// after which the request is still answerable.
    pub fn respond(&self, status: u16, headers: Option<&[u8]>, body: &[u8]) -> Result<(), HttpError> {
        let resp = Self::builder(status, headers)?
            .body(Body::from(body.to_vec()))
            .map_err(|e| HttpError::new("response", e.to_string()))?;
        self.send(resp)
    }

    /// (httpd:request-respond-file r 200 nil "/path"): answer with a
    /// file's bytes, which never cross the boundary — opened here on the
    /// calling thread (kind "io" if that fails, and the request stays
    /// answerable), streamed by tokio. Content-Length is set from the
    /// file unless HEADERS carries one.
    pub fn respond_file(&self, status: u16, headers: Option<&[u8]>, path: &str) -> Result<(), HttpError> {
        let file = std::fs::File::open(path).map_err(HttpError::io)?;
        let meta = file.metadata().map_err(HttpError::io)?;
        if !meta.is_file() {
            return Err(HttpError::new("io", format!("{path} is not a regular file")));
        }
        let mut b = Self::builder(status, headers)?;
        b.headers_mut()
            .unwrap()
            .entry(CONTENT_LENGTH)
            .or_insert_with(|| HeaderValue::from_str(&meta.len().to_string()).unwrap());
        let stream = ReaderStream::new(tokio::fs::File::from_std(file));
        let resp = b
            .body(Body::from_stream(stream))
            .map_err(|e| HttpError::new("response", e.to_string()))?;
        self.send(resp)
    }
}

// ---------------------------------------------------------------------------
// Probe: the suite's hermetic client (fetch's in-crate test server, mirrored)
// ---------------------------------------------------------------------------

/// What one probe connection has received: complete HTTP/1.1 responses
/// split off the byte stream, the unparsed tail, and whether the
/// connection is over.
struct Slot {
    ready: VecDeque<Vec<u8>>,
    buf: Vec<u8>,
    closed: bool,
    error: Option<String>,
}

type SharedSlot = Arc<(Mutex<Slot>, Condvar)>;

fn new_slot() -> SharedSlot {
    Arc::new((
        Mutex::new(Slot { ready: VecDeque::new(), buf: Vec::new(), closed: false, error: None }),
        Condvar::new(),
    ))
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Split one complete HTTP/1.1 response off the front of BUF: the head,
/// then Content-Length bytes, or chunks up to the empty one.
fn split_response(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    let head_end = find(buf, b"\r\n\r\n")? + 4;
    let head = String::from_utf8_lossy(&buf[..head_end]).to_ascii_lowercase();
    let end = if head.contains("transfer-encoding: chunked") {
        let body = &buf[head_end..];
        let z = if body.starts_with(b"0\r\n") { 0 } else { find(body, b"\r\n0\r\n")? + 2 };
        head_end + find(&body[z..], b"\r\n\r\n")? + z + 4
    } else {
        let len = head
            .lines()
            .find_map(|l| l.strip_prefix("content-length:"))
            .and_then(|v| v.trim().parse::<usize>().ok())
            .unwrap_or(0);
        head_end + len
    };
    (buf.len() >= end).then(|| buf.drain(..end).collect())
}

enum Mode {
    Once,
    Hold,
    Drip(Duration),
}

fn finish(slot: &SharedSlot, error: Option<String>) {
    let mut s = slot.0.lock().unwrap();
    if !s.buf.is_empty() {
        let partial = std::mem::take(&mut s.buf);
        s.ready.push_back(partial);
    }
    s.closed = true;
    if error.is_some() {
        s.error = error;
    }
    slot.1.notify_all();
}

async fn run_probe(addr: String, raw: Vec<u8>, mode: Mode, slot: SharedSlot) {
    let mut stream = match TcpStream::connect(&addr).await {
        Ok(s) => s,
        Err(e) => return finish(&slot, Some(e.to_string())),
    };
    let written = match &mode {
        Mode::Drip(every) => {
            // the head goes at once; what follows it (the body) drips, so
            // the body timer is what fires, not the head timer
            let split = find(&raw, b"\r\n\r\n").map(|i| i + 4).unwrap_or(0);
            let mut r = stream.write_all(&raw[..split]).await;
            for b in &raw[split..] {
                if r.is_err() {
                    break;
                }
                tokio::time::sleep(*every).await;
                r = stream.write_all(&[*b]).await;
            }
            r
        }
        _ => stream.write_all(&raw).await,
    };
    // a write that failed (the server answered early and closed — 408,
    // 413, 431 — then we hit its closed socket) still leaves that answer
    // to read; the write error is reported only if nothing arrives
    let write_error = written.err().map(|e| e.to_string());
    let mut chunk = vec![0u8; 16384];
    loop {
        match stream.read(&mut chunk).await {
            Ok(0) => return finish(&slot, write_error),
            Err(e) => return finish(&slot, Some(write_error.unwrap_or_else(|| e.to_string()))),
            Ok(n) => {
                let mut s = slot.0.lock().unwrap();
                s.buf.extend_from_slice(&chunk[..n]);
                let mut got = false;
                while let Some(r) = split_response(&mut s.buf) {
                    s.ready.push_back(r);
                    got = true;
                }
                if got {
                    slot.1.notify_all();
                    if matches!(mode, Mode::Once) {
                        s.closed = true;
                        return; // the stream drops here: "once" closes after the answer
                    }
                }
            }
        }
    }
}

/// One h2c request with prior knowledge; the slot gets
/// "<status>\r\n\r\n<body>".
async fn run_h2c(addr: String, path: String, slot: SharedSlot) {
    let r: Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> = async {
        let stream = TcpStream::connect(&addr).await?;
        let (mut sender, conn) =
            hyper::client::conn::http2::handshake(TokioExecutor::new(), TokioIo::new(stream)).await?;
        tokio::spawn(conn);
        let req = HttpRequest::builder().uri(format!("http://{addr}{path}")).body(Body::empty())?;
        let resp = sender.send_request(req).await?;
        let mut out = format!("{}\r\n\r\n", resp.status().as_u16()).into_bytes();
        let body = axum::body::to_bytes(Body::new(resp.into_body()), 1 << 20).await?;
        out.extend_from_slice(&body);
        Ok(out)
    }
    .await;
    match r {
        Ok(bytes) => {
            slot.0.lock().unwrap().ready.push_back(bytes);
            finish(&slot, None);
        }
        Err(e) => finish(&slot, Some(e.to_string())),
    }
}

struct ProbeInner {
    rt: Mutex<Option<Runtime>>,
    conns: Mutex<HashMap<u64, (SharedSlot, tokio::task::JoinHandle<()>)>>,
    next: AtomicU64,
}

impl ProbeInner {
    fn spawn<F: Future<Output = ()> + Send + 'static>(&self, slot: SharedSlot, f: F) -> Result<u64, HttpError> {
        let rt = self.rt.lock().unwrap();
        let rt = rt.as_ref().ok_or_else(|| HttpError::new("usage", "probe is shut down"))?;
        let task = rt.spawn(f);
        let id = self.next.fetch_add(1, SeqCst) + 1;
        self.conns.lock().unwrap().insert(id, (slot, task));
        Ok(id)
    }
    fn slot(&self, id: u64) -> Result<SharedSlot, HttpError> {
        self.conns
            .lock()
            .unwrap()
            .get(&id)
            .map(|(s, _)| s.clone())
            .ok_or_else(|| HttpError::new("usage", format!("no probe connection {id}")))
    }
    fn quiesce(&self, grace: Duration) {
        for (_, (_, task)) in self.conns.lock().unwrap().drain() {
            task.abort();
        }
        if let Some(rt) = self.rt.lock().unwrap().take() {
            rt.shutdown_timeout(grace);
        }
    }
}

/// The suite's hermetic client: raw HTTP/1.1 over a TCP connection it
/// controls byte by byte (a half-sent request line, a dripped body, a
/// pipelined pair), and one h2c request with prior knowledge. Its own
/// one-thread runtime, so it outlives a server under test. Not a client
/// for applications — fetch is.
#[rulisp::handle]
pub struct Probe {
    inner: Arc<ProbeInner>,
}

impl Drop for Probe {
    fn drop(&mut self) {
        for (_, (_, task)) in self.inner.conns.lock().unwrap().drain() {
            task.abort();
        }
        if let Some(rt) = self.inner.rt.lock().unwrap().take() {
            rt.shutdown_background();
        }
    }
}

#[rulisp::export]
impl Probe {
    /// (httpd:make-probe): a client with its own runtime thread.
    #[rulisp(constructor)]
    pub fn new() -> Result<Probe, HttpError> {
        let rt = Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("rulisp-httpd-probe")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|e| HttpError::new("runtime", e.to_string()))?;
        let inner = Arc::new(ProbeInner {
            rt: Mutex::new(Some(rt)),
            conns: Mutex::new(HashMap::new()),
            next: AtomicU64::new(0),
        });
        let mut reg = PROBES.lock().unwrap();
        reg.retain(|w| w.strong_count() > 0);
        reg.push(Arc::downgrade(&inner));
        Ok(Probe { inner })
    }

    /// (httpd:probe-send p "127.0.0.1:8080" raw "once"): connect and write
    /// RAW. MODE "once" reads one complete response and closes; "hold"
    /// keeps the connection open and reads until the server closes it;
    /// "drip:<ms>" writes the head at once, then one body byte every <ms>,
    /// and reads as "hold".
    /// Returns a connection id; nothing blocks here.
    pub fn send(&self, addr: &str, raw: &[u8], mode: &str) -> Result<u64, HttpError> {
        let mode = match mode {
            "once" => Mode::Once,
            "hold" => Mode::Hold,
            m => match m.strip_prefix("drip:").and_then(|n| n.parse::<u64>().ok()) {
                Some(ms) => Mode::Drip(Duration::from_millis(ms.max(1))),
                None => return Err(HttpError::new("usage", format!("unknown probe mode {m:?}"))),
            },
        };
        let slot = new_slot();
        self.inner.spawn(slot.clone(), run_probe(addr.to_string(), raw.to_vec(), mode, slot))
    }

    /// (httpd:probe-h2c p "127.0.0.1:8080" "/path"): one GET over HTTP/2
    /// with prior knowledge; `probe-poll` returns "<status>\r\n\r\n<body>".
    pub fn h2c(&self, addr: &str, path: &str) -> Result<u64, HttpError> {
        let slot = new_slot();
        self.inner.spawn(slot.clone(), run_h2c(addr.to_string(), path.to_string(), slot))
    }

    /// (httpd:probe-poll p id 100): the next complete response's octets,
    /// or NIL while none has arrived (waits at most 100 ms). Kind "gone"
    /// once the connection closed with nothing left to return, "io" when
    /// it failed (connection refused, reset).
    pub fn poll(&self, id: u64, wait_ms: u64) -> Result<Option<Vec<u8>>, HttpError> {
        refuse_reentry()?;
        let slot = self.inner.slot(id)?;
        let mut s = slot.0.lock().unwrap();
        if s.ready.is_empty() && !s.closed {
            s = slot.1.wait_timeout(s, capped(wait_ms)).unwrap().0;
        }
        if let Some(r) = s.ready.pop_front() {
            return Ok(Some(r));
        }
        if let Some(e) = &s.error {
            return Err(HttpError::new("io", e.clone()));
        }
        if s.closed {
            return Err(HttpError::new("gone", "connection closed with no response"));
        }
        Ok(None)
    }

    /// (httpd:probe-closed p id 100): T once the connection is over —
    /// the server closed it, or "once" did after its answer. Waits at
    /// most 100 ms.
    pub fn closed(&self, id: u64, wait_ms: u64) -> Result<bool, HttpError> {
        refuse_reentry()?;
        let slot = self.inner.slot(id)?;
        let mut s = slot.0.lock().unwrap();
        if !s.closed {
            s = slot.1.wait_timeout(s, capped(wait_ms)).unwrap().0;
        }
        Ok(s.closed)
    }

    /// Close connection ID from the client side (a client that left).
    pub fn close(&self, id: u64) -> Result<(), HttpError> {
        let (_, task) = self
            .inner
            .conns
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| HttpError::new("usage", format!("no probe connection {id}")))?;
        task.abort(); // drops the stream
        Ok(())
    }

    /// Tear the probe's runtime down, GRACE-MS at most 5 s.
    pub fn shutdown(&self, grace_ms: u64) -> Result<(), HttpError> {
        refuse_reentry()?;
        self.inner.quiesce(Duration::from_millis(grace_ms.min(5_000)));
        Ok(())
    }
}

/// The declared dump hook: quiesce every live server and probe, 2 s each
/// at most (BOUNDARY §10). Stop your pullers first — SBCL refuses to dump
/// with Lisp threads running; this hook covers the Rust threads.
#[rulisp::export]
pub fn shutdown_all() {
    let live: Vec<Arc<ServerInner>> = SERVERS.lock().unwrap().iter().filter_map(Weak::upgrade).collect();
    for s in live {
        s.quiesce(Duration::from_millis(2_000));
    }
    let probes: Vec<Arc<ProbeInner>> = PROBES.lock().unwrap().iter().filter_map(Weak::upgrade).collect();
    for p in probes {
        p.quiesce(Duration::from_millis(2_000));
    }
}

rulisp::module! {
    name: "httpd",
    handles: [Server, Request, Probe],
    fns: [
        Server::bind, Server::port, Server::pending, Server::in_flight, Server::connections,
        Server::is_down, Server::wait, Server::stop, Server::stopped, Server::shutdown,
        Request::take, Request::method, Request::path, Request::query, Request::version,
        Request::peer, Request::headers, Request::header, Request::body, Request::alive,
        Request::respond, Request::respond_file,
        Probe::new, Probe::send, Probe::h2c, Probe::poll, Probe::closed, Probe::close,
        Probe::shutdown,
        shutdown_all,
    ],
    on_dump: shutdown_all,
}

# Security policy

## Reporting a vulnerability

Please report security issues privately via GitHub's **Report a
vulnerability** button on
<https://github.com/onlyarche/rulisp/security/advisories> rather than in a
public issue. Include the affected version, the Lisp implementation and OS,
and a reproduction if you have one. Expect an acknowledgement within a few
days; fixes ship as a patch release, and a bad version is yanked from
crates.io.

## Threat model — what counts as a vulnerability here

rulisp is an **in-process FFI bridge**. Rust code loaded through it runs
with the full privileges of the Lisp image and shares its address space:
there is no sandbox between a glue crate and your program, by design. So:

**In scope** — bugs where Lisp code that uses only generated wrappers and
the documented API can reach memory unsafety:

- use-after-free, double-free or type confusion through handles (the cell
  state machine, generation gates, or reload/image-restore paths)
- dangling or mismatched allocator frees for strings, byte buffers or
  vectors crossing the boundary
- a dead stored-callback id causing a dangling call instead of failing safe
- a manifest that makes the loader generate unsound bindings, or that gets
  half-applied
- panics or Lisp conditions escaping their documented containment

**Out of scope** — documented, contract-level properties:

- a glue crate's own `unsafe` code, or a crate you chose to wrap
- non-local Lisp exits (`throw`, `return-from`, restart transfers) out of a
  callback: documented UB, see BOUNDARY.md §6
- crash isolation: a Rust segfault or abort takes the image down; if you
  need isolation, run the Rust side out of process
- dependencies that install signal handlers (BOUNDARY.md §7 tells you to
  audit for these)
- loading an untrusted `.so`, which is equivalent to running untrusted code

If you want to run untrusted logic in-process, `examples/wasm` shows the
supported approach: the WASI sandbox, `wasm:make-wasi` (since 0.7).
`wasm:make-wasm`, the plain module runner, is for modules you trust: it
may run unmetered and bounds no memory.

`examples/httpd` (since 0.8) is a server that listens on a socket: what it
bounds, and what it does not, is listed after the sandbox's.

### What the WASI sandbox bounds, and what it does not

Each line of the first list is a test in `tests/suite/wasm.lisp`
(`wasm.wasi-*`), found or confirmed by attacking the finished sandbox.

It bounds:

- **instructions** — fuel is mandatory; out of fuel is a condition, also
  for a `(start)` section, and unbounded recursion stops at the
  interpreter's depth limit (guest frames are on the heap)
- **time inside host calls** — fuel does not meter what the host does for
  a WASI call, so that time has its own budget: one second plus a
  microsecond per unit of fuel (before it, 100,000 fuel of `random_get`
  ran 103 seconds)
- **memory** — one number for the linear memory, the table and the bytes
  kept from stdout and stderr together; one memory, one table
- **waiting** — `poll_oneoff` and sleep answer ENOTSUP at once
- **the filesystem** — only the directories you preopen, read-only,
  regular files and directories only (a FIFO, a device or a socket is
  EACCES); `..`, absolute paths and symlinks that lead outside are EPERM,
  for open and for stat alike
- **descriptors** — 256 open at once, all released when the run ends
- **the process** — no arguments, environment, stdio or directory is
  inherited; the exit code is a value

It does not bound:

- a bug in wasmi, wasi-common, cap-std or the glue: the sandbox is a
  budget for a guest, **not isolation from the host** — the crash-
  isolation bullet above applies to it as to every crate
- host memory beyond the number: about three times the memory limit is
  resident per live instance (memory, table, captured output) — and the
  number has to admit the module at all: one built by Rust asks for
  1.1 MiB of memory before it runs
- one host call in flight: it may touch the whole guest memory, or list a
  directory as large as you made it, before the time budget is checked
- the module file: reading and validating it is linear in its size, and
  you chose the file
- what the guest can learn: the real clocks, real entropy, the names and
  sizes of everything under a preopen, and the text of its symlinks
  (never the file a link outside points at)
- a filesystem that is itself slow, and a directory that changes under
  the guest while it runs

### What the HTTP server bounds, and what it does not

`examples/httpd` is HTTP/1.1 and h2c on hyper, in front of a Lisp pull
loop. Each line of the first list is a test in `tests/suite/httpd.lisp`
(`httpd.*`), found or confirmed by the review that attacked the server
before it merged (the planned adversarial pass was not run); the
limits are the nine arguments of `httpd:make-server`, and the veneer's
`web:server` gives them defaults.

It bounds:

- **time to send a request head** — HEAD-MS from the connection's first
  byte, and from accept for a client that sends nothing or only a prefix
  of the HTTP/2 preface (hyper's timer arms after that sniff, which has
  none of its own); the same timer bounds an idle keep-alive connection
  (`httpd.slowloris-is-closed`, `httpd.keep-alive-idle-is-closed`)
- **a request body** — BODY-CAP bytes, declared or chunked, is 413;
  BODY-MS to arrive is 408; the body is read before anything reaches
  Lisp (`httpd.body-cap-is-413`, `httpd.body-drip-is-408`)
- **bodies in memory** — at most QUEUE being read at once, whatever the
  protocol or the number of connections: an HTTP/2 client's streams share
  the same slots, so one connection cannot hold streams × BODY-CAP; with
  QUEUE parked and one per puller, bodies are at most (2 × QUEUE +
  pullers) × BODY-CAP (`httpd.bodies-in-flight-are-bounded`)
- **requests parked for Lisp** — QUEUE; one more waits QUEUE-WAIT-MS for
  a slot, then 503 with Retry-After, so a burst costs latency before it
  costs errors; a client that leaves while parked frees its slot
  (`httpd.queue-full-waits-then-503`, `httpd.client-that-left-is-pruned`)
- **open connections** — MAX-CONNECTIONS, a permit per accept; the next
  client waits in the kernel backlog with no descriptor opened in this
  process (`httpd.connection-cap-holds`)
- **a handler's time** — HANDLER-MS from arrival to answer, then 504 and
  the late answer is "gone"; 0, the REPL default, means never
  (`httpd.handler-timeout-is-504`)
- **every answer** — a request pulled and never answered is 500 when its
  handle is freed, by the veneer's `unwind-protect` or by the GC; stop is
  graceful (parked requests 503, pulled ones finish); after a crash of
  the Lisp side nothing is left waiting (`httpd.unanswered-request-is-
  500-on-free`, `httpd.stop-answers-parked-503-and-pulled-finish`)
- **what Lisp can put on the wire** — a header value with CR or LF, a
  block that is not CRLF-separated, a Transfer-Encoding, a Content-Length
  that is not the body's, a 1xx, a 204 or 304 with a body: each is
  refused before a byte is written, with the request still answerable
  (`httpd.header-injection-refused`, `httpd.framing-and-status-are-
  checked`)
- **a file answered** — `request-respond-file` sends regular files only,
  checked before the open, so a FIFO cannot block the Lisp thread; the
  bytes never cross the boundary (`httpd.respond-file-streams`)
- **hyper's own limits** — 100 request headers and a 400 KB head buffer
  (431 or a close); HTTP/2's 200 streams per connection, 1024 local
  resets, 16 KB frames and 1 MB windows at hyper's defaults
  (`httpd.header-bomb-is-refused`)
- **every wait on a Lisp thread** — 100 ms, whatever was asked for; the
  loop is in Lisp, so Ctrl-C lands within a tick (`httpd.waits-are-capped`)

It does not bound:

- **TLS** — there is none; the deployment story is a terminating proxy in
  front, which also means browsers speak HTTP/1.1 to it and HTTP/2
  arrives only from proxies and API clients with prior knowledge
- **a handler's work and heap** — what your Lisp does with a request is
  yours; HANDLER-MS bounds the client's wait, not the handler, and at the
  REPL default of 0 a debugger session holds its client until you answer
- **an idle HTTP/2 connection** — bounded only by MAX-CONNECTIONS, since
  the head timer is HTTP/1.1's; and hyper's HTTP/2 limits beyond their
  defaults
- **the kernel's backlog** — a client queued there when the server stops
  is reset, not answered; and a connection still sending its head at stop
  is given until HEAD-MS before `server-stopped` turns T
- **per-connection buffers** — about 0.4 MB of head buffer per HTTP/1.1
  connection and the 1 MB window per HTTP/2 one, times MAX-CONNECTIONS,
  beside the bodies above
- **an image dump with pullers alive** — the hook runs on every attempt:
  on SBCL the dump is refused, or saved if the pullers exited in time
  after their server stopped; on CCL an image saved with a puller alive
  faulted at exit. Stop first (`web:stop`), then dump
- **a bug in hyper, axum, tokio or the glue** — in-process, as every
  crate: the crash-isolation bullet above applies

## Supported versions

The latest release only, while the project is pre-1.0 (docs/stability.md §4 has the full support and deprecation policy).

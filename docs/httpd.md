# Rust events, Lisp handlers: the HTTP server example

`examples/httpd` is an HTTP/1.1 and h2c server whose handlers are Lisp
functions. Read it as the worked example of a pattern, not as a reason to
move a web app off a Lisp server: **Rust produces events, Lisp handles
them, and a queue sits between the two.**

Each side does what it is good at:

- **Rust** holds the connections, parses HTTP, runs the timers and the
  limits, and answers 503 when the queue is full. axum, hyper and tokio do
  this work; it has to be fast and memory-safe.
- **Lisp** runs the handlers. You redefine them at the REPL while the
  server runs, and a handler error opens the debugger on the request that
  caused it.
- **rulisp** keeps the seam safe. Rust never calls into Lisp: it puts each
  request on a queue, and a Lisp thread takes it off.

Why not let Rust call the handler directly? A tokio thread is not a Lisp
thread. Running Lisp on it means registering it with the Lisp, making it
cooperate with the Lisp's garbage collector, opening a debugger on a
thread that also serves thousands of connections, and unwinding a Ctrl-C
through Rust frames. With a queue, Lisp code only ever runs on threads
Lisp made, exactly as in a pure Lisp server. The cost is small: a waiting
Lisp thread wakes as soon as a request arrives. Every wait is capped at
100 ms only so that Ctrl-C reaches the loop, which lives in Lisp.

**For a plain web application, a Lisp server is the simpler choice.**
Hunchentoot or Clack have no seam to cross, and they offer sessions,
cookies, multipart, static files and TLS, which this example does not.
Reach for this shape when the events come from Rust in the first place,
or when you want hyper's limits and HTTP/2 in front of Lisp handlers.

## Hello

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/httpd/"))
(load (asdf:system-relative-pathname :rulisp "../examples/httpd/web.lisp"))

(web:with-server (s :port 8080)
  (web:serve s (lambda (r) (web:respond r 200 "Hello from Lisp!"))))
```

```
$ curl -si http://127.0.0.1:8080/
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
content-length: 16

Hello from Lisp!
```

`serve` runs on the thread that calls it and returns when the server
stops. Ctrl-C lands within 100 ms, because every wait inside the loop is
capped there, and `with-server` stops and frees the server on the way out.
For a REPL that stays yours, start pullers in their own threads:

```lisp
(defvar *s* (web:server :port 8080))
(web:start *s* (lambda (r) (web:respond r 200 "Hello from Lisp!")))
;; ... the REPL is free; redefine the handler's functions as you go
(web:stop *s*)
```

## JSON, routing, files

rulisp ships no JSON reader. Bring the one you like; here it is jzon.

```lisp
(ql:quickload :com.inuoe.jzon)
(setf *s* (web:server :port 8080))
(web:start *s*
  (lambda (r)
    (let ((path (web:request-path r)))
      (cond ((web:match-path "/users/:id" path)
             (let ((id (cdr (assoc "id" (web:match-path "/users/:id" path) :test #'string=))))
               (web:respond r 200 (com.inuoe.jzon:stringify
                                   (alexandria:plist-hash-table (list "id" id "name" "Ada") :test #'equal))
                            :content-type "application/json")))
            ((string= path "/echo")
             (web:respond r 200 (com.inuoe.jzon:stringify (com.inuoe.jzon:parse (web:request-text r)))
                          :content-type "application/json"))
            ((string= path "/index.html") (web:respond-file r "/srv/site/index.html"))
            (t (web:respond r 404 "not found"))))))
```

```
$ curl -s http://127.0.0.1:8080/users/42
{"id":"42","name":"Ada"}
$ curl -s -d '{"a":[1,2]}' http://127.0.0.1:8080/echo
{"a":[1,2]}
$ curl -s -o /dev/null -w '%{http_version} %{http_code}\n' --http2-prior-knowledge http://127.0.0.1:8080/users/1
2 200
```

`respond-file` hands the file to the server, which streams it; the bytes
never enter Lisp. The content type comes from the extension. A missing
file, a directory or a FIFO signals `web:http-error` with kind `"io"`, and
the request is still yours to answer.

A request offers `request-method`, `request-path`, `request-query`,
`query-params` (decoded pairs), `request-headers` (an alist),
`request-header`, `request-body` (octets), `request-text`, `request-peer`
and `request-version`. `match-path` returns the `:name` captures, `T` for
a match without captures, or `NIL`.

## The loop's contract

Every request is answered on every path. The client sees:

| Status | When |
|---|---|
| your status | the handler called `respond` or `respond-file` |
| 500 | the handler signalled, or returned without answering |
| 503 + `Retry-After: 1` | the queue stayed full for QUEUE-WAIT-MS, or the server stopped before a handler took the request |
| 504 | HANDLER-MS passed after the whole request arrived, without an answer |
| 413 | the body passed BODY-CAP |
| 408 | the body took longer than BODY-MS |
| 431 | more than 100 request headers |

A dropped request answers 500 when its handle is freed, not when the GC
gets to it. `serve` frees every request in `unwind-protect`, so a handler
that throws out of the loop still answers. A client that left before the
answer is a warning, not an error.

## Errors in a handler

`serve` defaults to `:debug t`. An error in the handler enters the
debugger in the handler's own frame, with the request still open and the
client waiting, and three restarts:

- `respond-500` answers 500 and goes on to the next request.
- `retry-handler` runs the handler again on the same request. Fix the
  function in the REPL first.
- `skip-request` drops the request; freeing it answers 500.

With `:debug nil`, the default for `start`, an error is a warning naming
the request and a bare 500. A handler that returns without answering is
also a warning.

## Limits

`web:server` takes these keywords. Every one is enforced by the Rust side.

| Keyword | Default | Past it |
|---|---|---|
| `:queue` | 256 | requests parked for Lisp; one more waits QUEUE-WAIT-MS, then 503 |
| `:queue-wait-ms` | 1000 | 503 with `Retry-After: 1` |
| `:max-connections` | 512 | the next client waits in the kernel's backlog |
| `:body-cap` | 1048576 | 413 |
| `:head-ms` | 10000 | a request head not finished in time closes the connection; also the idle bound of an HTTP/1.1 keep-alive connection |
| `:body-ms` | 10000 | 408 |
| `:handler-ms` | 0 | 504; 0 means never, so a debugger session at the REPL can hold its client |
| `:workers` | 2 | tokio threads, not Lisp threads |

Memory for request bodies is bounded by the queue, whatever the protocol:
at most QUEUE bodies being read and QUEUE parked, plus one per handler,
each at most BODY-CAP. Each connection also holds up to about 0.4 MB of
head buffer on HTTP/1.1, or a 1 MB window on HTTP/2. Size `:queue` and
`:body-cap` together. SECURITY.md lists what the server bounds and what it
does not.

## Testing your handlers

Start a server on port 0 in the same image, ask `web:port` which port it
got, and use any client. `httpd:make-probe` is the raw client rulisp's own
suite uses; it can send half a request or hold a connection open.

## Deploying

Load the crate with `use-crate` from a checkout, or with
`rulisp:load-blob-crate` from a directory of per-platform builds named as
docs/distribution.md describes. Put
nginx or caddy in front for TLS. Browsers then speak HTTP/1.1 to the
proxy; h2c reaches the server from proxies and API clients that use prior
knowledge, since there is no ALPN without TLS.

To ship an image, call `web:stop` **before** `uiop:dump-image`. The
crate's dump hook stops every server either way, but a puller thread
still alive at dump time makes SBCL refuse the image, and on CCL an image
saved that way faulted at exit. In the restored image a server from
before the dump is stale: start a fresh one in `uiop:*image-entry-point*`.

## Not in this example

TLS, sessions and cookies, multipart, static-file middleware, a Clack
adapter, streaming uploads and responses, server-sent events.

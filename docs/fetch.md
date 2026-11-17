# Rust owns the threads, Lisp pulls: the HTTPS client example

`examples/fetch` is an async HTTP and HTTPS client: reqwest over rustls,
on a tokio runtime that a rulisp handle owns. Read it as the worked
example of a pattern, the crate that owns threads: **Rust runs the
transfers on its own threads, and Lisp pulls the results with waits
capped at 100 ms.**

The crate and its `http:` veneer are example code. Like the other examples
and their Lisp veneers, they are a pattern to copy, not a frozen surface:
none is among the four versioned surfaces of docs/stability.md §1.

Each side does what it is good at:

- **Rust** holds the sockets and the TLS sessions, runs the timers,
  admits or refuses a request, and buffers a bounded number of body
  chunks ahead of the reader.
- **Lisp** runs the loop. It asks for the next chunk; between two asks an
  interrupt, a restart or a non-local exit works as it does anywhere.
- **rulisp** keeps the seam safe. No Rust thread calls into Lisp: the
  crate declares no callback, so no foreign thread ever enters the image.

Why not a callback per chunk? Pushing would adopt a foreign thread into
the Lisp for each chunk, and it has no natural backpressure. Pulling
needs no thread to cross, and a reader that stops asking holds the
transfer back. The price is the cap. A Lisp thread inside a foreign call
cannot be interrupted, so no call in the loop waits longer than 100 ms;
the caller loops, and Ctrl-C lands within a tick. Two waits are longer:
shutdown up to its grace, the dump hook up to 2 s per client (Limits).

**For a plain HTTP request, a Lisp client is the simpler choice.**
Dexador or Drakma have no Rust seam to cross and need no cargo. Reach for this
shape when the threads are Rust's in the first place, or when you want
rustls and no system OpenSSL under an HTTPS client.

## Loading

```lisp
(ql:quickload :rulisp)
(rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/fetch/"))
(load (asdf:system-relative-pathname :rulisp "../examples/fetch/http.lisp"))
```

`use-crate` builds the crate with cargo and generates `FETCH`: 24
functions, the handle classes `fetch:client` and `fetch:req`, and the
condition `fetch:http-error`. `http.lisp` is the veneer, the `HTTP`
package and its thirteen exports. Load it after the crate.

Without a Rust toolchain, a release's `fetch` blob loads the same crate
(docs/usage.md, Case A):

```lisp
(rulisp:load-blob-crate #p"/path/to/blobs/" "fetch")
(load "/path/to/http.lisp")
```

The blob carries the `FETCH` package only. The veneer is one source file,
`examples/fetch/http.lisp`, to copy beside your code and `load`.

## Hello

```lisp
(http:with-client (c)
  (let ((base (fetch:client-start-test-server c)))
    (http:get c (format nil "~A/bytes/5" base))))
;; => #(120 120 120 120 120)
;;    200
;;    (("content-type" . "application/octet-stream") ("content-length" . "5")
;;     ("connection" . "close"))
```

`http:get` returns `(values body status headers)`. The body is a vector
of octets; `babel:octets-to-string` makes text of it. The headers are an
alist, names in lower case, duplicates kept, values decoded as Latin-1 so
that every octet survives. A repeated name's values are adjacent and in
wire order; the names come in reqwest's order, not always the wire's.

`fetch:client-start-test-server` starts the crate's own loopback HTTP/1.1
server and returns its base URL. rulisp's suite uses it, and so does this
page, so that every form here runs without a network. Any `http://` or
`https://` URL takes its place. HTTPS is rustls with the webpki roots
compiled in: there is no system OpenSSL to install, and `make test-fetch`
fails if one enters the dependency graph. The suite never leaves
loopback, so it exercises no TLS.

`with-client` shuts the client down and frees it on the way out, however
you leave. A client that outlives one form:

```lisp
(defvar *c* (http:client))
(defvar *base* (fetch:client-start-test-server *c*))

(babel:octets-to-string
 (http:request *c* "POST" (format nil "~A/echo-headers" *base*)
               :headers '(("x-one" . "1") ("accept" . "*/*"))
               :body (babel:string-to-octets "hello")))
;; => "x-one: 1
;;    accept: */*
;;    user-agent: rulisp-fetch/0.1
;;    accept-encoding: gzip
;;    host: 127.0.0.1:34567
;;    content-length: 5
;;
;;    "
```

`http:request` takes the client, a method string, a URL and the keywords
`:headers`, `:body`, `:sink`, `:timeout-ms`, `:max-bytes` and
`:expect-success`; `http:get` is `request` with `"GET"`. `:headers` is an
alist whose values are strings or octet vectors. `:body` is octets: a
string signals `rulisp:invalid-argument`. Several Lisp threads may share
one client.

## Downloading to a file

```lisp
(http:download *c* (format nil "~A/bytes/1000000" *base*)
               (merge-pathnames "big.bin" (uiop:temporary-directory)))
;; => NIL
;;    200
;;    (("content-type" . "application/octet-stream")
;;     ("content-length" . "1000000") ("connection" . "close"))
```

`download` is `get` with `:sink`: a Rust thread writes the body to the
file, and no byte of it enters the Lisp heap. The first value is `NIL`.
The file is created, or truncated, when the response head arrives,
whatever the status, and a transfer that fails leaves what it wrote: a
404 leaves a file holding the 404's body, a body cut off by `:max-bytes`
a partial one.

## Errors

A failed request signals `http:http-error`. Four readers:

| Reader | Value |
|---|---|
| `http-error-kind` | a string, one of the tokens below |
| `http-error-detail` | the message |
| `http-error-status` | the HTTP status if the head had arrived, else `NIL` |
| `http-error-url` | the URL; `NIL` from `http:client` and for a refused header |

```lisp
(handler-case (http:get *c* (format nil "~A/status/404" *base*))
  (http:http-error (e)
    (list (http:http-error-kind e) (http:http-error-status e)
          (http:http-error-detail e))))
;; => ("status" 404 "server returned 404")
```

Dispatch on the kind, never on the detail:

| Kind | When |
|---|---|
| `"status"` | the answer was not 2xx; `:expect-success nil` returns the three values instead |
| `"transport"` | reqwest could not complete the exchange: a refused connection, DNS, TLS, a scheme it does not speak |
| `"timeout"` | `:timeout-ms` passed, before the head or in the middle of the body |
| `"too-large"` | the body passed `:max-bytes` |
| `"io"` | the `:sink` file could not be created or written |
| `"request"` | the request could not be built: a URL or a method that does not parse, a header the veneer refuses |
| `"busy"` | `:max-in-flight` requests are in flight already; nothing is queued |
| `"stalled"` | a full buffer sat undrained for `:stall-ms`: the pull loop stopped pulling |
| `"cancelled"` | `fetch:req-cancel`, or the client was shut down under the request |
| `"usage"` | the client is shut down |
| `"runtime"` | the tokio runtime or the reqwest client could not be built, or the test server could not bind |
| `"error"` | the slot's default, for a Rust error without a `kind:` prefix; the crate emits none |

Underneath, the generated functions signal `fetch:http-error`, a
`rulisp:rust-error` whose message is `"kind: detail"`, and the veneer
splits it at the first colon. Conditions that are not Rust errors pass
through as they are: `rulisp:freed-handle-error` for a client already
freed, `rulisp:invalid-argument` for a body that is not octets.

## Retrying

`request` establishes the restart `http:retry-request` around the whole
exchange. Invoking it sends the request again from the start. The veneer
has no policy of its own, neither a count nor a backoff; a handler has:

```lisp
(let ((tries 0))
  (handler-case
      (handler-bind ((http:http-error
                       (lambda (e)
                         (when (and (equal "status" (http:http-error-kind e))
                                    (< (incf tries) 3))
                           (invoke-restart 'http:retry-request)))))
        (http:get *c* (format nil "~A/status/503" *base*)))
    (http:http-error (e) (list (http:http-error-status e) :tries tries))))
;; => (503 :TRIES 3)
```

## Limits

`http:client` takes four keywords, and `with-client` passes its options
on to it. Two of `http:request`'s keywords are limits, and one of
`http:shutdown`'s. The rest are fixed in the crate.

| Limit | Default | Past it |
|---|---|---|
| a wait inside one foreign call | 100 ms, fixed | `req-read`, `req-wait` and `client-next-ready` return; the caller loops |
| `:threads` | 2 | tokio worker threads, not Lisp threads |
| `:max-in-flight` | 16 | the next request is kind `"busy"` |
| `:queue-chunks` | 8 | chunks buffered per request; the transfer waits for the reader |
| `:stall-ms` | 30000 | kind `"stalled"`; 0 means 30000 |
| `:max-bytes` | `http:*max-bytes*`, 268435456 (256 MiB); 0 with `:sink` | kind `"too-large"`; 0 means unlimited |
| `:timeout-ms` | 30000 | kind `"timeout"`; 0 means none |
| the ready queue | 4096 ids, fixed | the oldest id is dropped |
| `http:shutdown`'s `:grace-ms` | 100 | 5000 at most, whatever was asked; a thread still inside a system call outlives it |
| the dump hook | 2000 ms per client, fixed | the same, and the dump goes on |
| a header | — | kind `"request"`, before a byte is sent |

The client's numbers are unsigned integers. Out-of-range values are
clamped, not refused: `:threads` 1–64, `:max-in-flight` and
`:queue-chunks` 1–4096. `:stall-ms`, `:timeout-ms` and `:max-bytes` are
taken as given, 0 aside.

`:timeout-ms` covers the whole exchange, body included, so a long
download wants a larger value. With 0 nothing in the example bounds the
time: `:stall-ms` watches a full buffer, not a silent server.

`:max-bytes` counts bytes received, not a Content-Length the peer may
omit. While a buffered body is assembled the Lisp heap holds it twice,
as chunks and as the vector they are copied into.

A refused header is an empty name, a name with a space, a separator or a
character outside printable ASCII, or a value with CR, LF or NUL in it.

SECURITY.md lists what the client bounds and what it does not.

## Driving the pull loop yourself

`request` is a loop over the generated functions. Write the loop yourself
for progress, for several transfers at once, or to cancel:

```lisp
(let ((r (fetch:make-req *c* "GET" (format nil "~A/bytes/300000" *base*)
                         nil nil nil 30000 0)))
  (unwind-protect
       (loop for chunk = (fetch:req-read r 65536 100)
             while (or chunk (not (fetch:req-done r)))
             when chunk sum (length chunk))
    (rulisp:free r)))
;; => 300000
```

`make-req` takes eight positional arguments: client, method, URL, header
block, body, sink path, timeout in ms, body cap. The block, the body and
the path may be `NIL`; a timeout or a cap of 0 means none. The transfer
starts at once. `req-read` returns a chunk, or `NIL` when none came
within the wait; `req-done` tells "not yet" from "the end". Buffered
bytes come out before an error does. Freeing a request cancels it, and
so does the garbage collector for one you dropped; every ending returns
the request's slot.

The header block is octets, each field `name: value` and a CRLF.
`make-req` checks that framing, trims the whitespace around a name, and
refuses a field without a colon, a name that is not then a token and a
value with a control octet other than a tab. It cannot see a CRLF that
was inside a value: that is two fields by then. The veneer's check is
the one that stops it, so keep it if you build blocks yourself.

| Function | Returns |
|---|---|
| `make-client threads max-in-flight queue-chunks stall-ms` | a client; four positional arguments, no defaults |
| `client-in-flight c` | the number of requests that have not settled |
| `client-is-down c` | `T` once the client is shut down |
| `client-next-ready c wait-ms` | the id of a request that settled, or `NIL` |
| `client-shutdown c grace-ms` | nothing; cancels every request and stops the runtime |
| `client-start-test-server c` | the base URL of a loopback test server |
| `make-req …` | a request, already running |
| `req-id r` | an integer, counted from 1 for each client; what `client-next-ready` hands out |
| `req-status r` | the status; 0 until the head arrives |
| `req-head-done r` | `T` once the head has arrived |
| `req-headers r` | the response header block, octets |
| `req-header r name` | one value as a string, or `NIL`; the name matches in any case, and a value that is not UTF-8 comes back lossy |
| `req-received r` | body octets received so far |
| `req-total r` | the Content-Length, or `NIL` without one |
| `req-buffered r` | octets received and not yet read |
| `req-read r max-bytes wait-ms` | a chunk of at most MAX-BYTES octets (0: the chunk as it came), or `NIL` |
| `req-wait r wait-ms` | `T` if the request has settled |
| `req-settled r` | `T` once the transfer has ended; buffered bytes may remain |
| `req-done r` | `T` once it is settled and drained: the loop's end |
| `req-failed r` | `T` if it ended in an error |
| `req-error-kind r`, `req-error-message r` | the kind and the detail, or `NIL` |
| `req-cancel r` | nothing; the request settles as `"cancelled"` |
| `shutdown-all` | nothing; the dump hook, shuts every live client down |

Six of these are called by neither the veneer nor the rest of the suite:
`req-id`, `req-settled`, `req-failed`, `req-head-done`, `req-header` and
`req-buffered`. The test `fetch.progress-accessors` holds them. A
seventh, `shutdown-all`, is called by name nowhere either: it runs as
the dump hook (`fetch.dump-hook-quiesces`).

## Shutting down, and dumping an image

`http:shutdown` cancels every request and stops the runtime, waiting up
to `:grace-ms` for it. After it a new request is refused at once with
kind `"usage"`. `rulisp:free` on a client that was never shut down
cancels too and does not wait.

The crate declares a dump hook. `uiop:dump-image` runs it, and it shuts
down every live client, so that their tokio threads exit before the image
is written. In the restored image a client from before the dump is stale:
using it signals `rulisp:stale-handle-error`, and a fresh one works.

## Not in this example

A cookie jar, a redirect policy (reqwest's default follows ten hops),
proxy settings (reqwest reads `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`
and `NO_PROXY` from the environment), client certificates and extra
roots, multipart, streaming request bodies, a callback per chunk.

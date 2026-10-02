;;; examples/httpd suite: the HTTP server whose handlers are a Lisp pull
;;; loop, exercised against 127.0.0.1 only through the crate's own Probe
;;; client (no network, no CI flakiness, no second use-crate build).
;;;
;;; Every test states what a failure would mean, because the failure modes
;;; here are hangs, wedged images and clients left waiting, not wrong
;;; return values. Every wait has at least a second of slack over the
;;; server timeout it exercises (300 ms at most), so a regression fails
;;; instead of hanging. Reuses fetch.lisp's helpers (`err-kind`,
;;; `kind-of-signal`, `os-thread-count`); the system loads it first.

(in-package #:rulisp/test)

(def-suite* :rulisp-httpd)

(defvar *httpd-crate* nil)
(defvar *httpd-server* nil "The shared server: queue 8, two workers, eight connections,
64 KiB bodies, 1 s head and body timers, 200 ms queue wait, no handler timeout.")
(defvar *probe* nil)

(defun httpd-fn (name)
  (or (find-symbol name "HTTPD") (error "HTTPD:~A missing" name)))

(defun hc (name &rest args) (apply (httpd-fn name) args))

(defun ensure-httpd ()
  "Lazy on purpose: `make dist-dryrun` loads this file with cargo
unreachable, so nothing builds at load time. The shared server and probe
are recreated when a dump-hook test took them down."
  (unless *httpd-crate*
    (setf *httpd-crate*
          (rulisp:use-crate (asdf:system-relative-pathname
                             :rulisp "../examples/httpd/"))))
  (when (and *httpd-server* (hc "SERVER-IS-DOWN" *httpd-server*))
    (rulisp:free *httpd-server*)
    (setf *httpd-server* nil))
  (unless *httpd-server*
    (setf *httpd-server* (hc "MAKE-SERVER" "127.0.0.1:0" 8 2 8 65536 1000 1000 200 0)))
  (when (and *probe* (hc "PROBE-IS-DOWN" *probe*))
    (rulisp:free *probe*)
    (setf *probe* nil))
  (unless *probe*
    (setf *probe* (hc "MAKE-PROBE")))
  *httpd-crate*)

(defun ms-since (start)
  (/ (* 1000 (- (get-internal-real-time) start))
     internal-time-units-per-second))

(defun addr (server) (format nil "127.0.0.1:~D" (hc "SERVER-PORT" server)))

(defun settled-os-thread-count ()
  "The OS thread count once it has held still for 300 ms (a freed server's
runtime winds down in the background), or NIL where /proc is unavailable."
  (let ((n (os-thread-count)) (start (get-internal-real-time)) (held 0))
    (when n
      (loop while (and (< held 6) (< (ms-since start) 3000))
            do (sleep 0.05)
               (let ((m (os-thread-count)))
                 (if (eql m n) (incf held) (setf n m held 0))))
      n)))

(defmacro with-httpd-server ((var &key (queue 8) (workers 1) (connections 8)
                                  (body-cap 65536) (head-ms 1000) (body-ms 1000)
                                  (queue-wait-ms 200) (handler-ms 0))
                             &body body)
  "A server on a free loopback port, torn down in the documented order:
stop, poll stopped, shutdown, free."
  `(let ((,var (hc "MAKE-SERVER" "127.0.0.1:0" ,queue ,workers ,connections ,body-cap
                   ,head-ms ,body-ms ,queue-wait-ms ,handler-ms)))
     (unwind-protect (progn ,@body)
       (hc "SERVER-STOP" ,var)
       (loop repeat 50 until (hc "SERVER-STOPPED" ,var 100))
       (hc "SERVER-SHUTDOWN" ,var 2000)
       (rulisp:free ,var))))

;;; --- the wire, from Lisp -------------------------------------------------

(defun utf8 (string) (babel:string-to-octets string :encoding :utf-8))
(defun text (octets) (babel:octets-to-string octets :encoding :utf-8))

(defun raw-request (method path &key (headers '(("host" . "t"))) body)
  "An HTTP/1.1 request as octets. BODY is octets; its Content-Length is added."
  (let ((head (with-output-to-string (o)
                (format o "~A ~A HTTP/1.1~C~C" method path #\Return #\Linefeed)
                (dolist (h headers)
                  (format o "~A: ~A~C~C" (car h) (cdr h) #\Return #\Linefeed))
                (when body
                  (format o "content-length: ~D~C~C" (length body) #\Return #\Linefeed))
                (format o "~C~C" #\Return #\Linefeed))))
    (concatenate '(vector (unsigned-byte 8)) (utf8 head) (or body #()))))

(defun crlf-block (&rest pairs)
  "(\"name\" \"value\" ...) -> the CRLF header block as octets."
  (utf8 (with-output-to-string (o)
            (loop for (n v) on pairs by #'cddr
                  do (format o "~A: ~A~C~C" n v #\Return #\Linefeed)))))

(defun response-head-end (octets)
  (search #(13 10 13 10) octets))

(defun response-status (octets)
  "The status of a raw HTTP/1.1 response, or of the probe's h2c answer."
  (let ((s (text (subseq octets 0 (min 16 (length octets))))))
    (if (and (>= (length s) 9) (string= "HTTP/" s :end2 5))
        (parse-integer s :start 9 :junk-allowed t)
        (parse-integer s :junk-allowed t))))

(defun response-body (octets)
  (subseq octets (+ 4 (response-head-end octets))))

(defun response-header-values (octets name)
  "Every value of header NAME in a raw response, in wire order."
  (let ((head (text (subseq octets 0 (response-head-end octets))))
        (needle (format nil "~(~A~): " name)))
    (loop for line in (uiop:split-string head :separator (string #\Linefeed))
          for l = (string-right-trim '(#\Return) line)
          when (and (> (length l) (length needle))
                    (string-equal needle l :end2 (length needle)))
            collect (subseq l (length needle)))))

(defun send (server raw &optional (mode "once"))
  (hc "PROBE-SEND" *probe* (addr server) raw mode))

(defun poll-until (id &optional (ms 3000))
  "The next response on probe connection ID within MS, else NIL (never a hang)."
  (let ((start (get-internal-real-time)))
    (loop for r = (hc "PROBE-POLL" *probe* id 100)
          when r return r
          when (> (ms-since start) ms) return nil)))

(defun closed-within (id ms)
  (let ((start (get-internal-real-time)))
    (loop thereis (hc "PROBE-CLOSED" *probe* id 100)
          while (< (ms-since start) ms))))

;;; --- a Lisp handler loop in its own thread -------------------------------

(defstruct puller thread (stop nil) (empties 0) (errors 0))

(defun start-puller (server fn &key (name "httpd puller"))
  "A thread that pulls every request from SERVER and answers it with FN,
freeing the handle whatever FN does. The loop ends when STOP-PULLER asks or
the server is stopped (\"usage\")."
  (let ((p (make-puller)))
    (setf (puller-thread p)
          (bt:make-thread
           (lambda ()
             (handler-case
                 (loop until (puller-stop p)
                       do (when (hc "SERVER-WAIT" server 50)
                            (let ((r (handler-case (hc "TAKE-REQUEST" server)
                                       (rulisp:rust-error (e)
                                         (if (string= (err-kind e) "empty")
                                             (progn (incf (puller-empties p)) nil)
                                             (error e))))))
                              (when r
                                (unwind-protect
                                     (handler-case (funcall fn r)
                                       (error (e)
                                         (incf (puller-errors p))
                                         (format *error-output* "~&puller: ~A~%" e)))
                                  (rulisp:free r))))))
               ;; "usage" after stop ends the loop; so does a stale or
               ;; freed server — never a debugger in a non-interactive run
               (error () nil)))
           :name name))
    p))

(defun stop-puller (p)
  (setf (puller-stop p) t)
  (bt:join-thread (puller-thread p)))

(defmacro with-puller ((server fn) &body body)
  `(let ((%p (start-puller ,server ,fn)))
     (unwind-protect (progn ,@body) (stop-puller %p))))

(defun echo-path (r)
  "The reference handler: 200, the path as the body."
  (hc "REQUEST-RESPOND" r 200 nil (utf8 (hc "REQUEST-PATH" r))))

;;; ---------------------------------------------------------------------------
;;; Contract: the shape the design promised
;;; ---------------------------------------------------------------------------

(test httpd.manifest-has-no-stored-callbacks
  "A Lisp handler cannot answer through a callback (a stored callback
returns no value to Rust), so the server pulls. Declaring even one stored
callback would also force compile-file and a C toolchain on ECL at
binding-generation time. A failure here means someone added a doorbell."
  (ensure-httpd)
  (let ((raw (rulisp::crate-manifest-source *httpd-crate*)))
    (is (not (search ":stored-callback" raw)))))

(test httpd.waits-are-capped
  "A Lisp thread inside a foreign call cannot be interrupted; an uncapped
wait makes the image un-Ctrl-C-able. A failure here is a twenty-second
stall per wait (the asked-for wait), where the cap says 100 ms."
  (ensure-httpd)
  (with-httpd-server (s)
    (is (plusp (hc "SERVER-PORT" s)))
    (let ((start (get-internal-real-time)))
      (hc "SERVER-WAIT" s 20000)
      (let ((ms (ms-since start)))
        (is (< ms 500) "server-wait 20000 on an idle server took ~,0F ms" ms)))
    (let ((start (get-internal-real-time)))
      (is (not (hc "SERVER-STOPPED" s 20000)))
      (let ((ms (ms-since start)))
        (is (< ms 500) "server-stopped 20000 on a live server took ~,0F ms" ms)))
    (let ((id (send s (utf8 "GET /half") "hold"))
          (start (get-internal-real-time)))
      (is (null (hc "PROBE-POLL" *probe* id 20000)))
      (let ((ms (ms-since start)))
        (is (< ms 500) "probe-poll 20000 with nothing arrived took ~,0F ms" ms))
      (hc "PROBE-CLOSE" *probe* id))
    (is (string= "usage" (kind-of-signal (hc "MAKE-SERVER" "localhost:0" 8 1 8 65536 1000 1000 200 0)))
        "a hostname would resolve on the Lisp thread with no cap; ADDR is a literal ip:port")))

(test httpd.idle-wait-is-nil-not-a-condition
  "The serve loop's idle path is a NIL, not a handler-case: `server-wait`
answers NIL on an idle tick and T when something is parked; `take-request`
on an empty queue is the typed kind \"empty\" (racing pullers), and both
report \"usage\" once the server is stopped — never a hang, never a host
condition."
  (ensure-httpd)
  (let ((s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0)))
    (unwind-protect
         (progn
           (is (null (hc "SERVER-WAIT" s 50)))
           (is (= 0 (hc "SERVER-PENDING" s)))
           (is (= 0 (hc "SERVER-IN-FLIGHT" s)))
           (is (string= "empty" (kind-of-signal (hc "TAKE-REQUEST" s))))
           (is (not (hc "SERVER-IS-DOWN" s)))
           (hc "SERVER-STOP" s)
           (is (hc "SERVER-IS-DOWN" s))
           (is (string= "usage" (kind-of-signal (hc "SERVER-WAIT" s 50))))
           (is (string= "usage" (kind-of-signal (hc "TAKE-REQUEST" s))))
           (is (loop repeat 50 thereis (hc "SERVER-STOPPED" s 100))
               "server-stopped never turned T after stop on an idle server"))
      (hc "SERVER-SHUTDOWN" s 2000)
      (rulisp:free s))))

(test httpd.no-thread-adoption
  "The pull design must never adopt a foreign thread into the Lisp: the
server's threads are tokio's (WORKERS of them, visible to the OS only) and
`server-shutdown` takes them down again. A failure here is a Lisp thread
that was not there before, or Rust threads that outlive the server."
  (ensure-httpd)
  ;; warm up, in the documented order: the first handle may start the
  ;; host's finalizer thread, and a bare free would leave the warm-up's
  ;; worker exiting in the background while the baseline is read
  ;; (shutdown joins it)
  (with-httpd-server (w) (hc "SERVER-WAIT" w 1))
  (let ((lisp-before (length (bt:all-threads)))
        (os-before (settled-os-thread-count))
        (s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0)))
    (unwind-protect
         (progn
           (with-puller (s #'echo-path)
             (dotimes (i 20)
               (let ((id (send s (raw-request "GET" (format nil "/t/~D" i)))))
                 (is (equal (format nil "/t/~D" i) (text (response-body (poll-until id))))))))
           (is (= lisp-before (length (bt:all-threads))))
           (when os-before
             ;; join-thread returns before the OS thread is gone from /proc
             (loop repeat 100 until (= (+ os-before 1) (or (os-thread-count) 0)) do (sleep 0.01))
             (is (= (+ os-before 1) (os-thread-count))
                 "one tokio worker asked for, OS threads went ~D -> ~D"
                 os-before (os-thread-count)))
           (hc "SERVER-STOP" s)
           (loop repeat 50 until (hc "SERVER-STOPPED" s 100))
           (hc "SERVER-SHUTDOWN" s 2000)
           (is (= lisp-before (length (bt:all-threads))))
           (when os-before
             (loop repeat 100 while (> (or (os-thread-count) 0) os-before)
                   do (sleep 0.01))
             (is (<= (or (os-thread-count) 0) os-before)
                 "OS threads did not return to ~D after shutdown" os-before)))
      (rulisp:free s))))

;;; ---------------------------------------------------------------------------
;;; Protocol: what the Lisp side sees and what the client gets
;;; ---------------------------------------------------------------------------

(test httpd.hello-round-trip
  "Method, path, query, version, peer, headers and body cross intact; the
answer carries its status, the Lisp-set header and a Content-Length."
  (ensure-httpd)
  (let (seen)
    (with-puller (*httpd-server*
                  (lambda (r)
                    (setf seen (list (hc "REQUEST-METHOD" r) (hc "REQUEST-PATH" r)
                                     (hc "REQUEST-QUERY" r) (hc "REQUEST-VERSION" r)
                                     (hc "REQUEST-PEER" r) (text (hc "REQUEST-HEADERS" r))
                                     (hc "REQUEST-HEADER" r "X-Trace")
                                     (text (hc "REQUEST-BODY" r))))
                    (hc "REQUEST-RESPOND" r 201 (crlf-block "x-answer" "yes"
                                                            "content-type" "text/plain")
                        (utf8 "hello back"))))
      (let* ((id (send *httpd-server*
                       (raw-request "POST" "/hello/world?x=1&y=2"
                                    :headers '(("host" . "t") ("x-trace" . "abc"))
                                    :body (utf8 "payload"))))
             (resp (poll-until id)))
        (is (not (null resp)) "no response within 3 s")
        (when resp
          (is (= 201 (response-status resp)))
          (is (equal '("yes") (response-header-values resp "x-answer")))
          (is (equal '("10") (response-header-values resp "content-length")))
          (is (equal "hello back" (text (response-body resp)))))
        (destructuring-bind (method path query version peer headers trace body) seen
          (is (equal "POST" method))
          (is (equal "/hello/world" path))
          (is (equal "x=1&y=2" query))
          (is (equal "HTTP/1.1" version))
          (is (and (> (length peer) 10) (string= "127.0.0.1:" peer :end2 10))
              "peer is ~S" peer)
          (is (search (format nil "x-trace: abc~C~C" #\Return #\Linefeed) headers))
          (is (equal "abc" trace))
          (is (equal "payload" body)))))))

(test httpd.headers-are-lossless
  "Duplicates and their order survive both ways: the request block keeps
both x-a values in order (names are grouped, as hyper's header map keeps
them), `request-header` picks the first, and two set-cookie headers go
out in the order Lisp wrote them."
  (ensure-httpd)
  (let (block first)
    (with-puller (*httpd-server*
                  (lambda (r)
                    (setf block (text (hc "REQUEST-HEADERS" r))
                          first (hc "REQUEST-HEADER" r "x-a"))
                    (hc "REQUEST-RESPOND" r 200 (crlf-block "set-cookie" "a=1"
                                                            "set-cookie" "b=2")
                        (utf8 "ok"))))
      (let ((resp (poll-until (send *httpd-server*
                                    (raw-request "GET" "/h"
                                                 :headers '(("host" . "t") ("x-a" . "1")
                                                            ("x-b" . "mid") ("x-a" . "2")))))))
        (is (not (null resp)))
        (when resp
          (is (equal '("a=1" "b=2") (response-header-values resp "set-cookie"))))
        (is (equal "1" first))
        (let ((a1 (search "x-a: 1" block)) (b (search "x-b: mid" block)) (a2 (search "x-a: 2" block)))
          (is (and a1 b a2 (< a1 a2)) "block was ~S" block))))))

(test httpd.keep-alive-serves-two-requests
  "Two pipelined requests on one connection get two answers, in order."
  (ensure-httpd)
  (with-puller (*httpd-server* #'echo-path)
    (let* ((id (send *httpd-server*
                     (concatenate '(vector (unsigned-byte 8))
                                  (raw-request "GET" "/first") (raw-request "GET" "/second"))
                     "hold"))
           (a (poll-until id)) (b (poll-until id)))
      (is (equal "/first" (and a (text (response-body a)))))
      (is (equal "/second" (and b (text (response-body b)))))
      (hc "PROBE-CLOSE" *probe* id))))

(test httpd.body-cap-is-413
  "The body is read under the cap before anything reaches Lisp: one byte
over is 413 whether the length is declared or chunked; the cap itself is
200. A failure means a hostile body reaches the Lisp heap."
  (ensure-httpd)
  (with-puller (*httpd-server*
                (lambda (r) (hc "REQUEST-RESPOND" r 200 nil
                                (utf8 (format nil "~D" (length (hc "REQUEST-BODY" r)))))))
    (let ((at-cap (make-array 65536 :element-type '(unsigned-byte 8) :initial-element 65))
          (over (make-array 65537 :element-type '(unsigned-byte 8) :initial-element 66)))
      (let ((resp (poll-until (send *httpd-server* (raw-request "POST" "/b" :body at-cap)))))
        (is (eql 200 (and resp (response-status resp))))
        (is (equal "65536" (and resp (text (response-body resp))))))
      (let ((resp (poll-until (send *httpd-server* (raw-request "POST" "/b" :body over)))))
        (is (eql 413 (and resp (response-status resp)))))
      ;; chunked, no Content-Length: one 65537-byte chunk
      (let* ((head (utf8 (format nil "POST /c HTTP/1.1~C~Chost: t~C~Ctransfer-encoding: chunked~C~C~C~C~X~C~C"
                                   #\Return #\Linefeed #\Return #\Linefeed #\Return #\Linefeed
                                   #\Return #\Linefeed 65537 #\Return #\Linefeed)))
             (tail (utf8 (format nil "~C~C0~C~C~C~C" #\Return #\Linefeed #\Return #\Linefeed
                                   #\Return #\Linefeed)))
             (resp (poll-until (send *httpd-server*
                                     (concatenate '(vector (unsigned-byte 8)) head over tail)))))
        (is (eql 413 (and resp (response-status resp))))))))

(test httpd.body-drip-is-408
  "A body that arrives a byte at a time is answered 408 at BODY-MS, so a
slow sender cannot hold a connection's worth of buffer for long."
  (ensure-httpd)
  (with-httpd-server (s :body-ms 300)
    (let* ((start (get-internal-real-time))
           (resp (poll-until (send s (raw-request "POST" "/d" :body (utf8 "0123456789"))
                                   "drip:100")
                             3000)))
      (is (eql 408 (and resp (response-status resp))))
      (is (< (ms-since start) 2500)))))

(test httpd.slowloris-is-closed
  "A half-sent request line, a connection that sends nothing, and one that
sends a prefix of the HTTP/2 preface are all closed at HEAD-MS while a
whole request on another connection is answered. The first is hyper's
header timer; the other two are the accept loop's own watchdog — hyper's
timer arms only after the 24-byte protocol sniff, which has none (the
review found a silent client holding its permit forever). A failure here
is a connection, and a slot under the cap, held open for free."
  (ensure-httpd)
  (with-httpd-server (s :head-ms 300)
    (with-puller (s #'echo-path)
      (let ((half (send s (utf8 "GET /never-finished") "hold"))
            (silent (send s (utf8 "") "hold"))
            (preface (send s (utf8 (format nil "PRI * HTTP/2.0~C~C~C~CSM~C~C"
                                           #\Return #\Linefeed #\Return #\Linefeed
                                           #\Return #\Linefeed))
                           "hold"))
            (start (get-internal-real-time)))
        (let ((whole (poll-until (send s (raw-request "GET" "/whole")))))
          (is (equal "/whole" (and whole (text (response-body whole))))))
        (is (closed-within half 2000) "the half request was not closed within 2 s")
        (is (closed-within silent 2000) "the silent connection was not closed within 2 s")
        (is (closed-within preface 2000) "the preface-prefix connection was not closed within 2 s")
        (is (< (ms-since start) 2500))
        (is (string= "gone" (kind-of-signal (hc "PROBE-POLL" *probe* half 10))))
        (loop repeat 20 until (= 0 (hc "SERVER-CONNECTIONS" s)) do (sleep 0.05))
        (is (= 0 (hc "SERVER-CONNECTIONS" s)) "~D connections still counted" (hc "SERVER-CONNECTIONS" s))))))

(test httpd.keep-alive-idle-is-closed
  "A keep-alive connection that sends nothing after its answer is closed at
HEAD-MS: the same timer bounds the idle wait for the next head."
  (ensure-httpd)
  (with-httpd-server (s :head-ms 300)
    (with-puller (s #'echo-path)
      (let ((id (send s (raw-request "GET" "/ka") "hold")))
        (is (equal "/ka" (text (response-body (poll-until id)))))
        (let ((start (get-internal-real-time)))
          (is (closed-within id 2000) "idle keep-alive connection not closed within 2 s")
          (is (< 200 (ms-since start) 2500) "closed after ~,0F ms" (ms-since start)))))))

(test httpd.h2c-prior-knowledge
  "HTTP/2 without TLS (prior knowledge) is served on the same port through
the same pull loop; the Lisp side sees HTTP/2.0 where an HTTP/1.1 request
says HTTP/1.1 (and HTTP/1.0 for a 1.0 client), and the host reaches Lisp
as a `host` header for h2 as for h1 — HTTP/2 carries it as :authority,
which the review found dropped on the floor."
  (ensure-httpd)
  (let (versions hosts)
    (with-puller (*httpd-server*
                  (lambda (r)
                    (push (hc "REQUEST-VERSION" r) versions)
                    (push (hc "REQUEST-HEADER" r "host") hosts)
                    (echo-path r)))
      (let ((h2 (poll-until (hc "PROBE-H2C" *probe* (addr *httpd-server*) "/two"))))
        (is (eql 200 (and h2 (response-status h2))))
        (is (equal "/two" (and h2 (text (response-body h2))))))
      (let ((h1 (poll-until (send *httpd-server* (raw-request "GET" "/one")))))
        (is (equal "/one" (and h1 (text (response-body h1))))))
      (let ((h10 (poll-until (send *httpd-server*
                                   (utf8 (format nil "GET /ten HTTP/1.0~C~Chost: t~C~C~C~C"
                                                 #\Return #\Linefeed #\Return #\Linefeed
                                                 #\Return #\Linefeed))))))
        (is (equal "/ten" (and h10 (text (response-body h10)))))))
    (is (equal '("HTTP/1.0" "HTTP/1.1" "HTTP/2.0") versions))
    (is (equal (list "t" "t" (addr *httpd-server*)) hosts) "hosts seen: ~S" hosts)))

(test httpd.respond-file-streams
  "A file's bytes never cross the boundary: `request-respond-file` opens it
on the Lisp thread and tokio streams it, so a 5 MiB answer conses almost
nothing in Lisp; a missing file is kind \"io\" before any crossing, and the
request stays answerable."
  (ensure-httpd)
  (let* ((path (uiop:tmpize-pathname (merge-pathnames "httpd-file.bin" (uiop:temporary-directory))))
         (size (* 5 1024 1024))
         (consed 0)
         (missing-kind nil)
         ;; a FIFO with no writer: open(2) on it blocks until one appears
         (fifo (when (and (uiop:os-unix-p) (not (uiop:os-windows-p)))
                 (let ((f (uiop:native-namestring
                           (uiop:tmpize-pathname (merge-pathnames "httpd.fifo" (uiop:temporary-directory))))))
                   (ignore-errors (delete-file f))
                   (and (zerop (nth-value 2 (uiop:run-program (list "mkfifo" f) :ignore-error-status t)))
                        f)))))
    (with-open-file (f path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
      (let ((chunk (make-array 65536 :element-type '(unsigned-byte 8))))
        (dotimes (i 65536) (setf (aref chunk i) (logand (* i 7) 255)))
        (dotimes (i (/ size 65536)) (write-sequence chunk f))))
    (unwind-protect
         (with-puller (*httpd-server*
                       (lambda (r)
                         ;; no fiveam `is` here: the puller is another thread
                         (if (string= "/missing" (hc "REQUEST-PATH" r))
                             (progn
                               (setf missing-kind
                                     (list (kind-of-signal (hc "REQUEST-RESPOND-FILE" r 200 nil
                                                               "/nonexistent/httpd/file"))
                                           (kind-of-signal (hc "REQUEST-RESPOND-FILE" r 200 (crlf-block "content-length" "1")
                                                               (uiop:native-namestring path)))
                                           (kind-of-signal (hc "REQUEST-RESPOND-FILE" r 200 nil
                                                               (uiop:native-namestring (uiop:temporary-directory))))))
                               (hc "REQUEST-RESPOND" r 404 nil (utf8 "no such file")))
                             (let ((before #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0))
                               (hc "REQUEST-RESPOND-FILE" r 200 nil (uiop:native-namestring path))
                               (setf consed (- #+sbcl (sb-ext:get-bytes-consed) #-sbcl 0 before))))))
           (let ((resp (poll-until (send *httpd-server* (raw-request "GET" "/file")) 10000)))
             (is (not (null resp)) "5 MiB file not received within 10 s")
             (when resp
               (is (eql 200 (response-status resp)))
               (is (equal (list (format nil "~D" size)) (response-header-values resp "content-length")))
               (let ((body (response-body resp)))
                 (is (= size (length body)))
                 (is (loop for i below (length body) by 4099
                           always (= (aref body i) (logand (* (mod i 65536) 7) 255)))
                     "the bytes differ from the file"))))
           #+sbcl (is (< consed (* 1024 1024)) "respond-file consed ~D bytes in Lisp" consed)
           (let ((resp (poll-until (send *httpd-server* (raw-request "GET" "/missing")))))
             (is (eql 404 (and resp (response-status resp))))
             (destructuring-bind (missing bad-length directory) missing-kind
               (is (equal "io" missing))
               (is (equal "response" bad-length) "a wrong Content-Length gave ~S" bad-length)
               (is (equal "io" directory) "a directory gave ~S" directory))))
      (ignore-errors (delete-file path)))
    ;; The FIFO, on a throwaway thread: the regression this guards (open
    ;; before stat) blocks the calling thread in open(2) for good, so it must
    ;; not be a puller the test would then join. If the thread has not
    ;; returned in 2 s, a shell opens the FIFO for writing to release it, and
    ;; the test fails instead of hanging.
    (when fifo
      (unwind-protect
           (let* ((id (send *httpd-server* (raw-request "GET" "/fifo")))
                  (r (progn (loop repeat 20 until (hc "SERVER-WAIT" *httpd-server* 50))
                            (hc "TAKE-REQUEST" *httpd-server*)))
                  (result nil)
                  (worker (bt:make-thread
                           (lambda ()
                             (let ((start (get-internal-real-time)))
                               (setf result (list (kind-of-signal (hc "REQUEST-RESPOND-FILE" r 200 nil fifo))
                                                  (ms-since start)))))
                           :name "fifo probe")))
             (loop repeat 40 until result do (sleep 0.05))
             (let ((returned (and result t)))
               (unless returned
                 (uiop:run-program (list "sh" "-c" (format nil "exec 3>'~A'; exec 3>&-" fifo))
                                   :ignore-error-status t))
               (bt:join-thread worker)
               (is (eq t returned) "respond-file on a writer-less FIFO did not return within 2 s (open before stat blocks)")
               (when returned
                 (is (equal "io" (first result)) "the FIFO gave ~S" (first result))
                 (is (< (second result) 500) "the FIFO refusal took ~,0F ms" (second result))))
             (hc "REQUEST-RESPOND" r 404 nil (utf8 "fifo"))
             (rulisp:free r)
             (is (eql 404 (response-status (poll-until id)))))
        (ignore-errors (delete-file fifo))))))

;;; ---------------------------------------------------------------------------
;;; Backpressure and terminal states: every request is answered on every path
;;; ---------------------------------------------------------------------------

(test httpd.queue-full-waits-then-503
  "A burst past the queue costs latency before it costs errors: with no
puller, six requests against a queue of two leave two parked and four
503s with Retry-After — after QUEUE-WAIT-MS, not at once (the probe saw
190 of 200 refused immediately). Pulling then answers the two."
  (ensure-httpd)
  (with-httpd-server (s :queue 2 :queue-wait-ms 200)
    (let* ((start (get-internal-real-time))
           (ids (loop for i below 6 collect (send s (raw-request "GET" (format nil "/q/~D" i)))))
           (statuses (make-list 6 :initial-element nil))
           (first-503 nil))
      ;; short polls, so the time the first 503 is seen is the time it came
      (loop until (= 4 (count 503 statuses))
            while (< (ms-since start) 2500)
            do (loop for id in ids for cell on statuses
                     when (null (car cell))
                       do (let ((r (hc "PROBE-POLL" *probe* id 10)))
                            (when r
                              (setf (car cell) (response-status r))
                              (when (and (eql (car cell) 503) (not first-503))
                                (setf first-503 (ms-since start)))))))
      (is (= 4 (count 503 statuses)) "statuses ~S" statuses)
      (is (= 2 (count nil statuses)))
      (is (and first-503 (> first-503 150)) "the first 503 came after ~A ms" first-503)
      (is (= 2 (hc "SERVER-PENDING" s)))
      ;; now pull and answer the two parked ones
      (with-puller (s #'echo-path)
        (loop for id in ids for st in statuses
              when (null st)
                do (let ((r (poll-until id)))
                     (is (eql 200 (and r (response-status r))))))
        (is (= 0 (hc "SERVER-PENDING" s)))))))

(test httpd.bodies-in-flight-are-bounded
  "Request bodies being read are at most QUEUE at a time, whatever the
protocol or the connection count: the slot is taken before the body is
read and released once the request is parked or refused. Without it one
HTTP/2 connection could hold 200 streams × BODY-CAP (the review measured
+113 MiB from a single client against a stated bound of 2 MiB). Here ten
slow HTTP/1.1 bodies against a queue of two: two are read, eight are 503
after the queue wait, and the gauge never passes two."
  (ensure-httpd)
  (with-httpd-server (s :queue 2 :queue-wait-ms 300 :body-ms 5000)
    (let* ((start (get-internal-real-time))
           (ids (loop for i below 10
                      collect (send s (raw-request "POST" (format nil "/slow/~D" i)
                                                   :body (utf8 "0123456789"))
                                    "drip:60")))
           (peak 0) (refused 0))
      (loop while (< (ms-since start) 1500)
            do (setf peak (max peak (hc "SERVER-READING" s)))
               (sleep 0.02))
      (is (<= peak 2) "~D bodies were being read at once against a queue of 2" peak)
      (dolist (id ids)
        (let ((r (hc "PROBE-POLL" *probe* id 10)))
          (when (and r (eql 503 (response-status r))) (incf refused))))
      (is (= 8 refused) "~D of 10 slow bodies were refused" refused)
      ;; the two that got slots are parked once their bodies arrived
      (loop repeat 40 until (= 2 (hc "SERVER-PENDING" s)) do (sleep 0.05))
      (is (= 2 (hc "SERVER-PENDING" s)))
      (is (= 0 (hc "SERVER-READING" s))))))

(test httpd.retry-after-on-503
  "The 503 for a full queue says when to come back."
  (ensure-httpd)
  (with-httpd-server (s :queue 1 :queue-wait-ms 100)
    (let* ((a (send s (raw-request "GET" "/a") "hold"))
           (b (progn (sleep 0.1) (send s (raw-request "GET" "/b"))))
           (resp (poll-until b)))
      (is (eql 503 (and resp (response-status resp))))
      (is (equal '("1") (and resp (response-header-values resp "retry-after"))))
      (hc "PROBE-CLOSE" *probe* a))))

(test httpd.client-that-left-is-pruned
  "A client that gives up while parked frees its slot: two such entries do
not refuse the next live request, `take-request` never hands out a request
whose client is gone before the take, and one that leaves after the take
reads as not alive and \"gone\" on respond. The probe measured eight dead
entries making later live clients 503 — the 503 storm after a stall."
  (ensure-httpd)
  (with-httpd-server (s :queue 2 :queue-wait-ms 200)
    (let ((dead (loop for i below 2 collect (send s (raw-request "GET" (format nil "/dead/~D" i)) "hold"))))
      (loop repeat 20 until (= 2 (hc "SERVER-PENDING" s)) do (sleep 0.05))
      (is (= 2 (hc "SERVER-PENDING" s)))
      (dolist (id dead) (hc "PROBE-CLOSE" *probe* id))
      (sleep 0.2)
      ;; the live one is parked, not refused: pruning made room
      (let* ((live (send s (raw-request "GET" "/live")))
             (early (hc "PROBE-POLL" *probe* live 300)))
        (is (null early) "the live request was answered ~S instead of parked"
            (and early (response-status early)))
        (let ((r (hc "TAKE-REQUEST" s)))
          (is (equal "/live" (hc "REQUEST-PATH" r)) "take handed out ~S" (hc "REQUEST-PATH" r))
          (is (hc "REQUEST-ALIVE" r))
          (hc "REQUEST-RESPOND" r 200 nil (utf8 "alive"))
          (rulisp:free r))
        (is (equal "alive" (text (response-body (poll-until live)))))
        (is (string= "empty" (kind-of-signal (hc "TAKE-REQUEST" s)))))
      ;; a client that leaves after the take
      (let ((late (send s (raw-request "GET" "/late") "hold")))
        (loop repeat 20 until (hc "SERVER-WAIT" s 50))
        (let ((r (hc "TAKE-REQUEST" s)))
          (hc "PROBE-CLOSE" *probe* late)
          (loop repeat 40 while (hc "REQUEST-ALIVE" r) do (sleep 0.05))
          (is (not (hc "REQUEST-ALIVE" r)))
          (is (string= "gone" (kind-of-signal (hc "REQUEST-RESPOND" r 200 nil (utf8 "x")))))
          (rulisp:free r))))))

(test httpd.unanswered-request-is-500-on-free
  "A pulled request freed without an answer answers 500 — the client is
never left waiting for a handler that gave up."
  (ensure-httpd)
  (let ((id (send *httpd-server* (raw-request "GET" "/dropped"))))
    (loop repeat 20 until (hc "SERVER-WAIT" *httpd-server* 50))
    (rulisp:free (hc "TAKE-REQUEST" *httpd-server*))
    (let ((resp (poll-until id 1000)))
      (is (eql 500 (and resp (response-status resp)))))))

(test httpd.abandoned-request-is-500-after-gc
  "A pulled request that becomes garbage answers 500 when its finalizer
runs. This is the probe's §5c shape — the handle taken inside a compiled
lambda and dropped — and the limit it showed stays true: a handle still
on a running thread's stack survived three full GCs, so the GC is not a
response path; the veneer's unwind-protect is."
  (ensure-httpd)
  (let ((id (send *httpd-server* (raw-request "GET" "/garbage"))))
    (loop repeat 20 until (hc "SERVER-WAIT" *httpd-server* 50))
    (funcall (compile nil '(lambda (take s) (funcall take s) nil)) (httpd-fn "TAKE-REQUEST") *httpd-server*)
    (tg:gc :full t)
    (let ((resp (loop repeat 50
                      thereis (hc "PROBE-POLL" *probe* id 100)
                      do (tg:gc :full t))))
      (is (eql 500 (and resp (response-status resp))) "no 500 within 5 s of GCs"))))

(test httpd.handler-timeout-is-504
  "With HANDLER-MS set, a request Lisp has not answered in time is 504 and
the late answer is \"gone\": in production a stuck handler cannot hold a
client forever. (0, the REPL default, lets a debugger session hold it.)"
  (ensure-httpd)
  (with-httpd-server (s :handler-ms 300)
    (let ((id (send s (raw-request "GET" "/slow"))))
      (loop repeat 20 until (hc "SERVER-WAIT" s 50))
      (let ((r (hc "TAKE-REQUEST" s)))
        (unwind-protect
             (let ((resp (poll-until id 2000)))
               (is (eql 504 (and resp (response-status resp))))
               (is (not (hc "REQUEST-ALIVE" r)))
               (is (string= "gone" (kind-of-signal (hc "REQUEST-RESPOND" r 200 nil (utf8 "late"))))))
          (rulisp:free r))))))

(test httpd.double-respond-is-usage
  "The second answer to one request is the typed \"usage\", and a bad
status or header block is \"response\" with the request still answerable."
  (ensure-httpd)
  (let ((id (send *httpd-server* (raw-request "GET" "/twice"))))
    (loop repeat 20 until (hc "SERVER-WAIT" *httpd-server* 50))
    (let ((r (hc "TAKE-REQUEST" *httpd-server*)))
      (unwind-protect
           (progn
             (is (string= "response" (kind-of-signal (hc "REQUEST-RESPOND" r 99 nil (utf8 "x")))))
             (hc "REQUEST-RESPOND" r 200 nil (utf8 "once"))
             (is (string= "usage" (kind-of-signal (hc "REQUEST-RESPOND" r 200 nil (utf8 "again"))))))
        (rulisp:free r))
      (is (equal "once" (text (response-body (poll-until id))))))))

(test httpd.header-injection-refused
  "CR or LF inside a header value, and a block that is not CRLF-separated,
are refused as \"response\" before anything is written — request splitting
cannot start from Lisp — and the request stays answerable afterwards."
  (ensure-httpd)
  (let ((id (send *httpd-server* (raw-request "GET" "/inject"))))
    (loop repeat 20 until (hc "SERVER-WAIT" *httpd-server* 50))
    (let ((r (hc "TAKE-REQUEST" *httpd-server*)))
      (unwind-protect
           (progn
             (is (string= "response"
                          (kind-of-signal (hc "REQUEST-RESPOND" r 200
                                              (utf8 (format nil "x-a: 1~Cx-b: 2~C" #\Linefeed #\Linefeed))
                                              (utf8 "x")))))
             (is (string= "response"
                          (kind-of-signal (hc "REQUEST-RESPOND" r 200
                                              (utf8 (format nil "x-a: 1~CSet-Cookie: evil~C~C"
                                                              #\Return #\Return #\Linefeed))
                                              (utf8 "x")))))
             (is (string= "response"
                          (kind-of-signal (hc "REQUEST-RESPOND" r 200
                                              (utf8 (format nil "x-a: 1~C~Cno colon here~C~C"
                                                              #\Return #\Linefeed #\Return #\Linefeed))
                                              (utf8 "x")))))
             (hc "REQUEST-RESPOND" r 200 (crlf-block "x-a" "1") (utf8 "clean")))
        (rulisp:free r))
      (let ((resp (poll-until id)))
        (is (equal "clean" (and resp (text (response-body resp)))))
        (is (equal '("1") (and resp (response-header-values resp "x-a"))))))))

(test httpd.stop-answers-parked-503-and-pulled-finish
  "`server-stop` is graceful: the parked request is 503 at once, the pulled
one keeps its connection until Lisp answers, and `server-stopped` turns T
only then. A failure is a client cut off mid-handler."
  (ensure-httpd)
  (let ((s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0)))
    (unwind-protect
         (let ((pulled-id (send s (raw-request "GET" "/pulled"))))
           (loop repeat 20 until (hc "SERVER-WAIT" s 50))
           (let ((r (hc "TAKE-REQUEST" s))
                 (parked-id (send s (raw-request "GET" "/parked"))))
             (loop repeat 20 until (= 1 (hc "SERVER-PENDING" s)) do (sleep 0.05))
             (hc "SERVER-STOP" s)
             (let ((parked (poll-until parked-id 2000)))
               (is (eql 503 (and parked (response-status parked)))))
             (is (not (loop repeat 3 thereis (hc "SERVER-STOPPED" s 100)))
                 "stopped turned T with a pulled request unanswered")
             (is (null (hc "PROBE-POLL" *probe* pulled-id 50)))
             (hc "REQUEST-RESPOND" r 200 nil (utf8 "finished"))
             (rulisp:free r)
             (is (equal "finished" (text (response-body (poll-until pulled-id)))))
             (is (loop repeat 20 thereis (hc "SERVER-STOPPED" s 100))
                 "stopped did not turn T within 2 s of the last answer")))
      (hc "SERVER-SHUTDOWN" s 2000)
      (rulisp:free s))))

(test httpd.stop-answers-a-request-waiting-for-a-slot
  "A request waiting for a queue slot when the server stops is 503 at once
like the parked one — not parked after the drain, to sit until shutdown or
be answered 504 for a handler that was never allowed to take it (the
review's race)."
  (ensure-httpd)
  (let ((s (hc "MAKE-SERVER" "127.0.0.1:0" 1 1 8 65536 1000 1000 3000 0)))
    (unwind-protect
         (let ((parked (send s (raw-request "GET" "/parked"))))
           (loop repeat 20 until (= 1 (hc "SERVER-PENDING" s)) do (sleep 0.05))
           (let ((waiting (send s (raw-request "GET" "/waiting"))))
             (sleep 0.3)
             (is (= 1 (hc "SERVER-PENDING" s)))
             (hc "SERVER-STOP" s)
             (let ((a (poll-until parked 1000)) (b (poll-until waiting 1000)))
               (is (eql 503 (and a (response-status a))))
               (is (eql 503 (and b (response-status b))) "the waiting request got ~S"
                   (and b (response-status b))))
             (is (= 0 (hc "SERVER-PENDING" s)))
             (is (loop repeat 20 thereis (hc "SERVER-STOPPED" s 100))
                 "stopped did not turn T within 2 s")))
      (hc "SERVER-SHUTDOWN" s 2000)
      (rulisp:free s))))

(test httpd.framing-and-status-are-checked
  "What hyper would assert on, or put on the wire wrongly, is refused as
\"response\" with the request still answerable: a Content-Length that is
not the body's (hyper's connection task panics on the mismatch), a
Transfer-Encoding (framing is hyper's), a 1xx (not a final response), a
204 with a body. A HEAD answer may announce a length over its empty body;
an empty 204 is fine. The connection count is back to zero afterwards —
a dying connection task must still release its permit."
  (ensure-httpd)
  (with-puller (*httpd-server*
                (lambda (r)
                  (let ((p (hc "REQUEST-PATH" r)))
                    (cond ((string= p "/checks")
                           (let ((kinds (list (kind-of-signal (hc "REQUEST-RESPOND" r 200 (crlf-block "content-length" "99") (utf8 "hello")))
                                              (kind-of-signal (hc "REQUEST-RESPOND" r 200 (crlf-block "content-length" "3") (utf8 "hello")))
                                              (kind-of-signal (hc "REQUEST-RESPOND" r 200 (crlf-block "transfer-encoding" "chunked") (utf8 "hello")))
                                              (kind-of-signal (hc "REQUEST-RESPOND" r 100 nil (utf8 "")))
                                              (kind-of-signal (hc "REQUEST-RESPOND" r 101 nil (utf8 "")))
                                              (kind-of-signal (hc "REQUEST-RESPOND" r 204 nil (utf8 "body"))))))
                             (hc "REQUEST-RESPOND" r 200 (crlf-block "content-length" "5" "x-kinds" (format nil "~{~A~^,~}" kinds))
                                 (utf8 "hello"))))
                          ((string= p "/empty204") (hc "REQUEST-RESPOND" r 204 nil (utf8 "")))
                          ((string= p "/head") (hc "REQUEST-RESPOND" r 200 (crlf-block "content-length" "5") (utf8 "")))
                          (t (echo-path r))))))
    (let ((resp (poll-until (send *httpd-server* (raw-request "GET" "/checks")))))
      (is (eql 200 (and resp (response-status resp))))
      (is (equal "hello" (and resp (text (response-body resp)))))
      (is (equal '("response,response,response,response,response,response")
                 (and resp (response-header-values resp "x-kinds")))))
    (let* ((id (send *httpd-server*
                     (concatenate '(vector (unsigned-byte 8))
                                  (raw-request "GET" "/empty204") (raw-request "GET" "/after"))
                     "hold"))
           (a (poll-until id)) (b (poll-until id)))
      (is (eql 204 (and a (response-status a))))
      (is (equal "/after" (and b (text (response-body b)))))
      (hc "PROBE-CLOSE" *probe* id))
    (let ((resp (poll-until (send *httpd-server*
                                  (raw-request "HEAD" "/head" :headers '(("host" . "t") ("connection" . "close")))))))
      (is (eql 200 (and resp (response-status resp))))
      (is (equal '("5") (and resp (response-header-values resp "content-length"))))
      (is (= 0 (length (response-body resp)))))
    (loop repeat 40 until (= 0 (hc "SERVER-CONNECTIONS" *httpd-server*)) do (sleep 0.05))
    (is (= 0 (hc "SERVER-CONNECTIONS" *httpd-server*)))))

(test httpd.after-shutdown-answers-immediately
  "On a shut-down server `server-wait` and `take-request` answer the typed
\"usage\" within the cap, `server-stopped` is T, and stop and shutdown are
idempotent — no wait on a runtime that is gone, no condition for stopping
twice."
  (ensure-httpd)
  (let ((s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0)))
    (hc "SERVER-STOP" s)
    (loop repeat 50 until (hc "SERVER-STOPPED" s 100))
    (hc "SERVER-SHUTDOWN" s 2000)
    (unwind-protect
         (let ((start (get-internal-real-time)))
           (is (string= "usage" (kind-of-signal (hc "SERVER-WAIT" s 600000))))
           (is (string= "usage" (kind-of-signal (hc "TAKE-REQUEST" s))))
           (is (hc "SERVER-STOPPED" s 600000))
           (is (< (ms-since start) 500))
           (let ((resp (handler-case (poll-until (send s (raw-request "GET" "/x")) 1000)
                         (rulisp:rust-error (e) (err-kind e)))))
             (is (equal "io" resp) "a connection to the closed port gave ~S" resp)))
      (rulisp:free s))))

(test httpd.free-without-stop-closes-connections
  "Pinned as design, not found as a bug: `rulisp:free` on a server with a
client parked returns at once and resets that client (Drop cannot block),
and the runtime's threads go away in the background. The orderly path is
stop, stopped, shutdown — the veneer walks it."
  (ensure-httpd)
  (with-httpd-server (w) (hc "SERVER-WAIT" w 1)) ; a stable OS-thread baseline
  (let* ((os-before (settled-os-thread-count))
         (s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0))
         (id (send s (raw-request "GET" "/parked") "hold")))
    (loop repeat 20 until (= 1 (hc "SERVER-PENDING" s)) do (sleep 0.05))
    (let ((start (get-internal-real-time)))
      (is (rulisp:free s))
      (is (< (ms-since start) 500)))
    (is (closed-within id 2000) "the parked client's connection was not closed within 2 s")
    (when os-before
      (loop repeat 200 while (> (or (os-thread-count) 0) os-before) do (sleep 0.01))
      (is (<= (or (os-thread-count) 0) os-before)
          "OS threads ~D did not return to ~D after free" (os-thread-count) os-before))))

(test httpd.connection-cap-holds
  "MAX-CONNECTIONS is a permit per accept: with eight clients holding half
requests against a cap of four, four are open and four wait in the kernel
backlog with no descriptor in this process (a file still opens); closing
four admits the rest. A failure is a flood exhausting the image's
descriptors — the reason the WASI sandbox caps at 256."
  (ensure-httpd)
  (with-httpd-server (s :connections 4 :head-ms 5000)
    (let ((ids (loop repeat 8 collect (send s (utf8 "GET /hold") "hold"))))
      (loop repeat 20 until (= 4 (hc "SERVER-CONNECTIONS" s)) do (sleep 0.05))
      (sleep 0.2)
      (is (= 4 (hc "SERVER-CONNECTIONS" s)))
      (let ((tmp (uiop:tmpize-pathname (merge-pathnames "httpd-cap.txt" (uiop:temporary-directory)))))
        (with-open-file (f tmp :direction :output :if-exists :supersede) (write-line "open" f))
        (is (probe-file tmp))
        (delete-file tmp))
      (dolist (id (subseq ids 0 4)) (hc "PROBE-CLOSE" *probe* id))
      (sleep 0.3)
      (is (= 4 (hc "SERVER-CONNECTIONS" s)) "the waiting four were not admitted")
      (dolist (id (subseq ids 4)) (hc "PROBE-CLOSE" *probe* id))
      (loop repeat 40 until (= 0 (hc "SERVER-CONNECTIONS" s)) do (sleep 0.05))
      (is (= 0 (hc "SERVER-CONNECTIONS" s))))))

(test httpd.header-bomb-is-refused
  "hyper's own limits hold before Lisp sees a byte: 101 header lines and a
request line past the read buffer are both refused (431, or the connection
closed) and never parked."
  (ensure-httpd)
  (let* ((many (loop for i below 101 collect (cons (format nil "x-h~D" i) "v")))
         (a (poll-until (send *httpd-server* (raw-request "GET" "/bomb" :headers many))))
         (huge (send *httpd-server*
                     (utf8 (format nil "GET /~A HTTP/1.1~C~Chost: t~C~C~C~C"
                                     (make-string 1100000 :initial-element #\a)
                                     #\Return #\Linefeed #\Return #\Linefeed #\Return #\Linefeed))))
         (b (handler-case (poll-until huge 3000) (rulisp:rust-error (e) (err-kind e)))))
    (is (eql 431 (and a (response-status a))) "101 headers gave ~S" (and a (response-status a)))
    (is (or (member b '("gone" "io") :test #'equal)
            (and (vectorp b) (eql 431 (response-status b))))
        "a 1.1 MB request line gave ~S" (if (vectorp b) (response-status b) b))
    (is (= 0 (hc "SERVER-PENDING" *httpd-server*)))))

(test httpd.concurrent-pullers-exactly-once
  "Four Lisp pullers against eight connections of twenty-five pipelined
requests: every request is answered exactly once with its own path, and
\"empty\" (a racing puller took it) never escapes the loop."
  (ensure-httpd)
  (with-httpd-server (s :queue 64 :workers 2 :connections 16)
    (let ((pullers (loop for i below 4 collect (start-puller s #'echo-path
                                                             :name (format nil "puller ~D" i)))))
      (unwind-protect
           (let* ((ids (loop for c below 8
                             collect (send s (apply #'concatenate '(vector (unsigned-byte 8))
                                                    (loop for i below 25
                                                          collect (raw-request "GET" (format nil "/c~D/r~D" c i))))
                                           "hold")))
                  (bodies (loop for c below 8 for id in ids
                                append (loop for i below 25
                                             collect (let ((r (poll-until id 5000)))
                                                       (and r (text (response-body r))))))))
             (is (= 200 (length bodies)))
             (is (= 200 (length (remove-duplicates bodies :test #'equal))))
             (is (null (member nil bodies)) "~D requests unanswered" (count nil bodies))
             (dolist (id ids) (hc "PROBE-CLOSE" *probe* id))
             (is (= 0 (reduce #'+ pullers :key #'puller-errors))))
        (mapc #'stop-puller pullers)))))

(test httpd.port-reuse-after-stop
  "The port is free again after stop, shutdown and free: a server can be
restarted where it was."
  (ensure-httpd)
  (let* ((s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 8 65536 1000 1000 200 0))
         (port (hc "SERVER-PORT" s)))
    (with-puller (s #'echo-path)
      (is (equal "/x" (text (response-body (poll-until (send s (raw-request "GET" "/x"))))))))
    (hc "SERVER-STOP" s)
    (loop repeat 50 until (hc "SERVER-STOPPED" s 100))
    (hc "SERVER-SHUTDOWN" s 2000)
    (rulisp:free s)
    (let ((again (handler-case (hc "MAKE-SERVER" (format nil "127.0.0.1:~D" port) 8 1 8 65536 1000 1000 200 0)
                   (rulisp:rust-error (e) (rulisp:rust-error-message e)))))
      (is (not (stringp again)) "rebinding port ~D: ~A" port again)
      (unless (stringp again)
        (is (= port (hc "SERVER-PORT" again)))
        (hc "SERVER-STOP" again)
        (loop repeat 50 until (hc "SERVER-STOPPED" again 100))
        (hc "SERVER-SHUTDOWN" again 2000)
        (rulisp:free again)))))

(test httpd.reload-while-serving
  "Reloading the crate (BOUNDARY §9) leaves the old server handle stale —
every call on it is `stale-handle-error`, `free` is T — and the shared
server is recreated, not reused."
  (ensure-httpd)
  (let ((old *httpd-server*))
    (hc "SERVER-STOP" old)
    (loop repeat 50 until (hc "SERVER-STOPPED" old 100))
    (hc "SERVER-SHUTDOWN" old 2000)
    (rulisp:free *probe*)
    (setf *probe* nil)
    (setf *httpd-crate*
          (rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/httpd/")))
    (is (eq :stale (handler-case (progn (hc "SERVER-PORT" old) :alive)
                     (rulisp:stale-handle-error () :stale))))
    (is (rulisp:free old))
    (setf *httpd-server* nil)
    (ensure-httpd)
    (with-puller (*httpd-server* #'echo-path)
      (is (equal "/after" (text (response-body (poll-until (send *httpd-server* (raw-request "GET" "/after"))))))))))

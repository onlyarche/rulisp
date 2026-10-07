;;;; A Lisp veneer over the generated HTTPD package.
;;;;
;;;; The generated bindings are the substrate: nine positional limits, a
;;;; wait, a take, a respond, one condition whose message is "kind: detail".
;;;; This is what you actually type — a server with keyword defaults, a
;;;; serve loop with the debugger in the handler's frame, header alists,
;;;; query parameters, a path matcher, and a stop that walks the documented
;;;; order (stop, stopped, shutdown) before the handle is freed. Load it
;;;; after the crate:
;;;;
;;;;   (rulisp:use-crate #p".../examples/httpd/")   ; or rulisp:load-blob-crate
;;;;   (load ".../examples/httpd/web.lisp")
;;;;
;;;;   (web:with-server (s :port 8080)
;;;;     (web:serve s (lambda (r) (web:respond r 200 "Hello from Lisp!"))))
;;;;
;;;; Every request is answered on every path: by the handler, by the
;;;; RESPOND-500 restart, or by the 500 that freeing an unanswered request
;;;; produces — when the handle is freed, not when the GC gets to it, which
;;;; is why SERVE frees in UNWIND-PROTECT.

(defpackage #:web
  (:use #:cl)
  (:export #:server #:port #:with-server #:serve #:start #:stop #:shutdown
           #:request-method #:request-path #:request-query #:query-params
           #:request-headers #:request-header #:request-body #:request-text
           #:request-peer #:request-version #:match-path
           #:respond #:respond-file
           #:http-error #:http-error-kind #:http-error-detail
           #:respond-500 #:retry-handler #:skip-request))

(in-package #:web)

(defun %fn (name)
  (or (find-symbol name "HTTPD")
      (error "the HTTPD package is not loaded — (rulisp:use-crate ...) first")))

(defmacro %call (name &rest args)
  `(funcall (%fn ,name) ,@args))

(defun %ms-since (start)
  (/ (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second))

;;; ---------------------------------------------------------------------------
;;; Conditions. The substrate reports one Rust error type whose message is
;;; "kind: detail"; the kind is a stable token (usage, empty, gone, response,
;;; io, runtime), so the veneer puts it in a slot instead of making callers
;;; parse prose.
;;; ---------------------------------------------------------------------------

(define-condition http-error (error)
  ((kind :initarg :kind :initform "error" :reader http-error-kind)
   (detail :initarg :detail :initform "" :reader http-error-detail))
  (:report (lambda (c s)
             (format s "HTTP ~A: ~A" (http-error-kind c) (http-error-detail c)))))

(defun %kind (e)
  "The kind token of a substrate error, and its detail."
  (let* ((m (rulisp:rust-error-message e)) (i (position #\: m)))
    (if i
        (values (subseq m 0 i) (string-left-trim " " (subseq m (1+ i))))
        (values "error" m))))

(defmacro %translating (&body body)
  "Turn the substrate's rust-error into an HTTP-ERROR with a kind slot."
  `(handler-case (progn ,@body)
     (rulisp:rust-error (e)
       (multiple-value-bind (kind detail) (%kind e)
         (error 'http-error :kind kind :detail detail)))))

;;; ---------------------------------------------------------------------------
;;; Header alists <-> the raw CRLF field block (fetch's codec)
;;; ---------------------------------------------------------------------------

(defun %validate-header (name value)
  "Refuse anything that could splice extra fields into the block. Once a
value containing CRLF is in the block it is, on the wire, two fields, and
no parser downstream can tell the difference (CWE-113). The substrate
refuses the same, as a second line of defence."
  (let ((n (string name)))
    (when (zerop (length n))
      (error 'http-error :kind "response" :detail "empty header name"))
    (loop for ch across n
          unless (and (< 32 (char-code ch) 127)
                      (not (find ch ":()<>@,;\\\"/[]?={} " :test #'char=)))
            do (error 'http-error :kind "response"
                                  :detail (format nil "illegal character in header name ~S" n))))
  (flet ((bad (b) (or (= b 13) (= b 10) (= b 0))))
    (if (stringp value)
        (loop for ch across value
              when (bad (char-code ch))
                do (error 'http-error :kind "response"
                                      :detail (format nil "CR, LF or NUL in the value of ~A" name)))
        (loop for b across value
              when (bad b)
                do (error 'http-error :kind "response"
                                      :detail (format nil "CR, LF or NUL in the value of ~A" name))))))

(defun %encode-headers (alist)
  "((\"content-type\" . \"text/html\") ...) -> octets, or NIL for no headers.
Values may be strings or octet vectors."
  (when alist
    (loop for (name . value) in alist do (%validate-header name value))
    (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer t)))
      (flet ((put (octets) (loop for b across octets do (vector-push-extend b out))))
        (loop for (name . value) in alist
              do (put (babel:string-to-octets (string name) :encoding :utf-8))
                 (put #(58 32))
                 (put (if (stringp value) (babel:string-to-octets value :encoding :utf-8) value))
                 (put #(13 10))))
      (coerce out '(simple-array (unsigned-byte 8) (*))))))

(defun %decode-headers (octets)
  "Octets -> ((name . value) ...), names downcased, duplicates kept in
order. Values are decoded as latin-1 so every octet round-trips."
  (let ((lines '()) (start 0) (len (length octets)))
    (loop for i from 0 below len
          when (= (aref octets i) 10)
            do (let ((end (if (and (> i start) (= (aref octets (1- i)) 13)) (1- i) i)))
                 (when (> end start) (push (subseq octets start end) lines))
                 (setf start (1+ i))))
    (when (< start len) (push (subseq octets start len) lines))
    (loop for line in (nreverse lines)
          for c = (position 58 line)
          when c
            collect (cons (string-downcase (babel:octets-to-string (subseq line 0 c) :encoding :latin-1))
                          (babel:octets-to-string
                           (subseq line (let ((v (1+ c)))
                                          (loop while (and (< v (length line)) (= (aref line v) 32))
                                                do (incf v))
                                          v))
                           :encoding :latin-1)))))

;;; ---------------------------------------------------------------------------
;;; Server
;;; ---------------------------------------------------------------------------

(defun server (&key (address "127.0.0.1") (port 0) (queue 256) (workers 2)
                    (max-connections 512) (body-cap 1048576)
                    (head-ms 10000) (body-ms 10000) (queue-wait-ms 1000) (handler-ms 0))
  "Bind ADDRESS:PORT (port 0 picks a free one; PORT tells which) and start
serving on WORKERS tokio threads. The limits, each with the status a
client sees when it is hit: QUEUE requests parked for Lisp (more wait
QUEUE-WAIT-MS for a slot, then 503 with Retry-After); MAX-CONNECTIONS open
(the next waits in the kernel backlog); BODY-CAP bytes per body (413);
HEAD-MS to send a head, also the idle keep-alive bound (closed); BODY-MS
to send a body (408); HANDLER-MS from arrival to answer (504) — 0, the
default, means never: at the REPL a debugger session may hold its client."
  (%translating
    (%call "MAKE-SERVER" (format nil "~A:~D" address port) queue workers max-connections
           body-cap head-ms body-ms queue-wait-ms handler-ms)))

(defun port (server) (%call "SERVER-PORT" server))

(defun shutdown (server &key (grace-ms 2000))
  "The orderly end, as the substrate documents it: stop accepting (parked
requests are 503, pulled ones may finish), wait up to GRACE-MS for the
connections to close, then take the runtime down. Pullers started with
START are not joined here — STOP does that."
  (%call "SERVER-STOP" server)
  (let ((start (get-internal-real-time)))
    (loop until (or (%call "SERVER-STOPPED" server 100)
                    (> (%ms-since start) grace-ms))))
  (%call "SERVER-SHUTDOWN" server grace-ms))

(defmacro with-server ((var &rest options) &body body)
  "A server for the extent of BODY, stopped and freed on the way out
however you leave — Ctrl-C included: SERVE's wait is capped at 100 ms, so
the interrupt lands within that, and the unwind runs STOP."
  `(let ((,var (server ,@options)))
     (unwind-protect (progn ,@body)
       ;; nested, so a condition from STOP cannot skip the free
       (unwind-protect (stop ,var)
         (rulisp:free ,var)))))

;;; ---------------------------------------------------------------------------
;;; The serve loop
;;; ---------------------------------------------------------------------------

(defvar %*answered* nil
  "Bound per request by the loop; RESPOND and RESPOND-FILE set it.")

(defun %respond-500 (req)
  (setf %*answered* t)
  (ignore-errors (%call "REQUEST-RESPOND" req 500 nil (make-array 0 :element-type '(unsigned-byte 8)))))

(defun %handle (req handler debug)
  "Run HANDLER on REQ with the three restarts in its dynamic extent, then
free REQ whatever happened — an unanswered request answers 500 when its
handle is freed."
  (let ((%*answered* nil)
        (method (%call "REQUEST-METHOD" req))
        (path (%call "REQUEST-PATH" req)))
    (unwind-protect
         (loop
           (restart-case
               (progn
                 (if debug
                     (funcall handler req)
                     (handler-case (funcall handler req)
                       (error (e)
                         (warn "handler for ~A ~A signaled ~A; answered 500" method path e)
                         (%respond-500 req))))
                 (unless %*answered*
                   (warn "handler for ~A ~A returned without responding; the client gets 500"
                         method path))
                 (return))
             (respond-500 ()
               :report "Answer this request 500 and go on to the next."
               (%respond-500 req)
               (return))
             (retry-handler ()
               :report "Run the handler again for this request."
               nil)
             (skip-request ()
               :report "Drop this request; its client gets 500 when the handle is freed."
               (return))))
      (rulisp:free req))))

(defun %serve (server handler wait-ms debug stop-cell)
  (loop
    (when (and stop-cell (car stop-cell)) (return))
    (let ((ready (handler-case (%call "SERVER-WAIT" server wait-ms)
                   (rulisp:rust-error (e)
                     (if (string= (%kind e) "usage")
                         (return)            ; the server was stopped
                         (%translating (error e)))))))
      (when ready
        (let ((req (handler-case (%call "TAKE-REQUEST" server)
                     (rulisp:rust-error (e)
                       (let ((kind (%kind e)))
                         (cond ((string= kind "empty") nil)   ; a racing puller took it
                               ((string= kind "usage") (return))
                               (t (%translating (error e)))))))))
          (when req (%handle req handler debug)))))))

(defun serve (server handler &key (wait-ms 100) (debug t))
  "Pull every request from SERVER on this thread and answer it with
HANDLER, a function of one request, until the server is stopped. With
DEBUG true (the default, for the REPL) an error in HANDLER enters the
debugger in the handler's frame with three restarts — RESPOND-500,
RETRY-HANDLER, SKIP-REQUEST — and the client waits meanwhile; with DEBUG
NIL it is a warning and a bare 500. A handler that returns without
responding is a warning, and the client gets 500 when the request is
freed. WAIT-MS is how long one idle tick waits (the substrate caps it at
100 ms, so Ctrl-C lands within that)."
  (%serve server handler wait-ms debug nil)
  server)

;;; --- several pullers in their own threads ----------------------------------

(defvar %*pullers* (make-hash-table :test #'eq)
  "server -> (stop-cell . threads), for servers started with START.")

(defun start (server handler &key (threads 4) (debug nil) (wait-ms 100))
  "Serve SERVER with HANDLER on THREADS new threads and return at once.
DEBUG defaults to NIL here — a debugger in a background thread helps
nobody — so a handler error is a warning and a 500. STOP joins the threads
and shuts the server down; do that before an image dump (SBCL refuses to
dump with other Lisp threads alive, and a refused dump has already run the
crate's hook, which stops every server)."
  (let ((cell (list nil)))
    (setf (gethash server %*pullers*)
          (cons cell
                (loop for i below threads
                      collect (bt:make-thread
                               (lambda () (%serve server handler wait-ms debug cell))
                               :name (format nil "web puller ~D" i)))))
    server))

(defun stop (server &key (grace-ms 2000))
  "Stop the pullers START made (each wakes within one 100 ms tick and is
joined), then SHUTDOWN. Safe to call for a server that was served with
SERVE or never served; calling it from inside a handler skips joining the
calling thread."
  (let ((entry (gethash server %*pullers*)))
    (when entry
      (setf (car (car entry)) t)
      (dolist (th (cdr entry))
        (unless (eq th (bt:current-thread))
          (bt:join-thread th)))
      (remhash server %*pullers*)))
  (shutdown server :grace-ms grace-ms))

;;; ---------------------------------------------------------------------------
;;; Reading a request
;;; ---------------------------------------------------------------------------

(defun request-method (req) (%call "REQUEST-METHOD" req))
(defun request-path (req) (%call "REQUEST-PATH" req))
(defun request-query (req) (%call "REQUEST-QUERY" req))
(defun request-version (req) (%call "REQUEST-VERSION" req))
(defun request-peer (req) (%call "REQUEST-PEER" req))
(defun request-body (req) (%call "REQUEST-BODY" req))

(defun request-headers (req)
  "The request headers as an alist of downcased names, duplicates kept."
  (%decode-headers (%call "REQUEST-HEADERS" req)))

(defun request-header (req name)
  "The first value of header NAME (case-insensitive), or NIL."
  (%call "REQUEST-HEADER" req (string name)))

(defun request-text (req &key (encoding :utf-8))
  "The body as a string."
  (babel:octets-to-string (request-body req) :encoding encoding))

(defun %percent-decode (string &key plus-is-space)
  "%XX and (in a query) + decoded; the octets read as UTF-8, latin-1 if
they are not UTF-8."
  (let ((out (make-array (length string) :element-type '(unsigned-byte 8) :fill-pointer 0))
        (i 0) (n (length string)))
    (loop while (< i n)
          do (let ((ch (char string i)))
               (cond ((and (char= ch #\%) (< (+ i 2) n)
                           (digit-char-p (char string (+ i 1)) 16)
                           (digit-char-p (char string (+ i 2)) 16))
                      (vector-push (parse-integer string :start (+ i 1) :end (+ i 3) :radix 16) out)
                      (incf i 3))
                     ((and plus-is-space (char= ch #\+))
                      (vector-push 32 out) (incf i))
                     (t
                      (loop for b across (babel:string-to-octets (string ch) :encoding :utf-8)
                            do (vector-push b out))
                      (incf i)))))
    (let ((octets (coerce out '(simple-array (unsigned-byte 8) (*)))))
      (or (ignore-errors (babel:octets-to-string octets :encoding :utf-8))
          (babel:octets-to-string octets :encoding :latin-1)))))

(defun query-params (req)
  "The query string as an alist of decoded (name . value) pairs, in
order; a name without \"=\" has the value \"\"."
  (let ((q (request-query req)))
    (when (and q (plusp (length q)))
      (loop for pair in (uiop:split-string q :separator "&")
            when (plusp (length pair))
              collect (let ((eq (position #\= pair)))
                        (cons (%percent-decode (subseq pair 0 eq) :plus-is-space t)
                              (if eq (%percent-decode (subseq pair (1+ eq)) :plus-is-space t) "")))))))

(defun match-path (pattern path)
  "Match PATH against PATTERN, where a segment \":name\" captures one path
segment. Returns the captures as an alist of (\"name\" . value) — or T for
a match with no captures — and NIL when the path does not match:
  (web:match-path \"/users/:id\" \"/users/42\")  =>  ((\"id\" . \"42\"))"
  (let ((ps (uiop:split-string pattern :separator "/"))
        (xs (uiop:split-string path :separator "/")))
    (when (= (length ps) (length xs))
      (let ((captures '()))
        (loop for p in ps for x in xs
              do (cond ((and (plusp (length p)) (char= (char p 0) #\:))
                        (push (cons (subseq p 1) (%percent-decode x)) captures))
                       ((string/= p x) (return-from match-path nil))))
        (or (nreverse captures) t)))))

;;; ---------------------------------------------------------------------------
;;; Answering
;;; ---------------------------------------------------------------------------

(defmacro %answering (req &body body)
  "A client that left is a warning, not an error: the handler did its job.
The request counts as answered only once the answer went out (or nobody
was left to take it); a refused answer leaves it the handler's to answer."
  `(handler-case (multiple-value-prog1 (progn ,@body) (setf %*answered* t))
     (rulisp:rust-error (e)
       (multiple-value-bind (kind detail) (%kind e)
         (if (string= kind "gone")
             (progn
               (setf %*answered* t)
               (warn "~A ~A: the client went away before the answer (~A)"
                     (%call "REQUEST-METHOD" ,req) (%call "REQUEST-PATH" ,req) detail))
             (error 'http-error :kind kind :detail detail))))))

(defun %with-content-type (headers content-type)
  (if (and content-type (not (assoc "content-type" headers :test #'string-equal)))
      (append headers (list (cons "content-type" content-type)))
      headers))

(defun respond (req status body &key headers content-type)
  "Answer REQ once. BODY is a string (sent as UTF-8, text/plain unless
CONTENT-TYPE says otherwise), an octet vector (application/octet-stream)
or NIL. HEADERS is an alist; names and values are checked for CRLF before
they reach the wire. Signals HTTP-ERROR \"usage\" on a second answer and
\"response\" for a status or header the substrate refuses (a 1xx, a 204
with a body, a Content-Length that is not the body's); a client that left
is a warning."
  (let* ((octets (etypecase body
                   (null (make-array 0 :element-type '(unsigned-byte 8)))
                   (string (babel:string-to-octets body :encoding :utf-8))
                   ((vector (unsigned-byte 8)) body)))
         (ct (or content-type
                 (typecase body
                   (string "text/plain; charset=utf-8")
                   (null nil)
                   (t (and (plusp (length octets)) "application/octet-stream"))))))
    (%answering req
      (%call "REQUEST-RESPOND" req status
             (%encode-headers (%with-content-type headers ct)) octets))))

(defparameter %*types*
  '(("html" . "text/html; charset=utf-8") ("htm" . "text/html; charset=utf-8")
    ("css" . "text/css; charset=utf-8") ("js" . "text/javascript; charset=utf-8")
    ("json" . "application/json") ("txt" . "text/plain; charset=utf-8")
    ("md" . "text/markdown; charset=utf-8") ("svg" . "image/svg+xml")
    ("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("ico" . "image/x-icon") ("pdf" . "application/pdf")
    ("wasm" . "application/wasm")))

(defun respond-file (req path &key (status 200) headers content-type)
  "Answer REQ with the regular file at PATH, streamed by the substrate —
the bytes never cross into Lisp. CONTENT-TYPE defaults from the extension
(html, css, js, json, png, ...; application/octet-stream otherwise); the
Content-Length is the file's. A missing file, a directory or a FIFO is
HTTP-ERROR \"io\", and the request is still yours to answer."
  (let* ((type (pathname-type (pathname path)))
         (ct (or content-type
                 (cdr (assoc type %*types* :test #'string-equal))
                 "application/octet-stream")))
    (%answering req
      (%call "REQUEST-RESPOND-FILE" req status
             (%encode-headers (%with-content-type headers ct))
             (uiop:native-namestring path)))))

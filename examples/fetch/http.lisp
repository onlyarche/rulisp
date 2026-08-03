;;;; A Lisp veneer over the generated FETCH package.
;;;;
;;;; The generated bindings are the substrate: they are what the boundary
;;;; can prove. This is what you actually type — conditions with slots,
;;;; restarts, WITH- macros, header alists, and (values body status
;;;; headers). Load it after the crate:
;;;;
;;;;   (rulisp:use-crate #p".../examples/fetch/")
;;;;   (load ".../examples/fetch/http.lisp")

(defpackage #:http
  (:use #:cl)
  (:shadow #:get)
  (:export #:client #:with-client #:shutdown
           #:request #:get #:download #:*max-bytes*
           #:http-error #:http-error-kind #:http-error-detail
           #:http-error-status #:http-error-url
           #:retry-request))

(in-package #:http)

(defun %fn (name)
  (or (find-symbol name "FETCH")
      (error "the FETCH package is not loaded — (rulisp:use-crate ...) first")))

(defmacro %call (name &rest args)
  `(funcall (%fn ,name) ,@args))

;;; ---------------------------------------------------------------------------
;;; Conditions. The substrate reports one Rust error type whose message is
;;; "kind: detail"; the kind is a stable token, so the veneer splits it out
;;; and puts it in a slot instead of making callers parse prose.
;;; ---------------------------------------------------------------------------

(define-condition http-error (error)
  ((kind :initarg :kind :initform "error" :reader http-error-kind)
   (detail :initarg :detail :initform "" :reader http-error-detail)
   (status :initarg :status :initform nil :reader http-error-status)
   (url :initarg :url :initform nil :reader http-error-url))
  (:report (lambda (c s)
             (format s "HTTP ~A~@[ (status ~D)~]~@[ for ~A~]: ~A"
                     (http-error-kind c) (http-error-status c)
                     (http-error-url c) (http-error-detail c)))))

(defun %split-kind (message)
  (let ((i (position #\: message)))
    (if i
        (values (subseq message 0 i) (string-left-trim " " (subseq message (1+ i))))
        (values "error" message))))

(defmacro %translating ((url &optional status) &body body)
  "Turn the substrate's rust-error into an HTTP-ERROR with a kind slot."
  `(handler-case (progn ,@body)
     (rulisp:rust-error (e)
       (multiple-value-bind (kind detail)
           (%split-kind (rulisp:rust-error-message e))
         (error 'http-error :kind kind :detail detail
                            :url ,url :status ,status)))))

;;; ---------------------------------------------------------------------------
;;; Header alists <-> the raw CRLF field block
;;; ---------------------------------------------------------------------------

(defun %validate-header (name value)
  "Refuse anything that could splice extra fields into the block. This is
the ONLY place request splitting can be stopped: once a value containing
CRLF is in the block it is, on the wire, simply two fields, and no parser
downstream can tell the difference (CWE-113)."
  (let ((n (string name)))
    (when (zerop (length n))
      (error 'http-error :kind "request" :detail "empty header name"))
    (loop for ch across n
          unless (and (< 32 (char-code ch) 127)
                      (not (find ch ":()<>@,;\\\"/[]?={} " :test #'char=)))
            do (error 'http-error :kind "request"
                                  :detail (format nil "illegal character in header name ~S" n))))
  (flet ((bad (b)
           (or (= b 13) (= b 10) (= b 0))))
    (if (stringp value)
        (loop for ch across value
              when (bad (char-code ch))
                do (error 'http-error :kind "request"
                                      :detail (format nil "CR, LF or NUL in the value of ~A"
                                                      name)))
        (loop for b across value
              when (bad b)
                do (error 'http-error :kind "request"
                                      :detail (format nil "CR, LF or NUL in the value of ~A"
                                                      name))))))

(defun %encode-headers (alist)
  "((\"accept\" . \"*/*\") ...) -> octets. Values may be strings or octet
vectors; octets pass through untouched, which is how you send a value that
isn't UTF-8. Names and values are validated first — see %VALIDATE-HEADER."
  (when alist
    (loop for (name . value) in alist do (%validate-header name value))
    (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer t)))
      (flet ((put (octets)
               (loop for b across octets do (vector-push-extend b out))))
        (loop for (name . value) in alist
              do (put (babel:string-to-octets (string name) :encoding :utf-8))
                 (put #(58 32))         ; ": "
                 (put (if (stringp value)
                          (babel:string-to-octets value :encoding :utf-8)
                          value))
                 (put #(13 10))))       ; CRLF
      (coerce out '(simple-array (unsigned-byte 8) (*))))))

(defun %decode-headers (octets)
  "Octets -> ((name . value) ...), preserving duplicates and wire order.
Values are decoded as latin-1 so every octet round-trips: an HTTP header
value is bytes, not text, and obs-text is legal."
  (let ((lines '())
        (start 0)
        (len (length octets)))
    (loop for i from 0 below len
          when (= (aref octets i) 10)
            do (let ((end (if (and (> i start) (= (aref octets (1- i)) 13))
                              (1- i)
                              i)))
                 (when (> end start)
                   (push (subseq octets start end) lines))
                 (setf start (1+ i))))
    (when (< start len)
      (push (subseq octets start len) lines))
    (loop for line in (nreverse lines)
          for c = (position 58 line)    ; #\:
          when c
            collect (cons (string-downcase
                           (babel:octets-to-string (subseq line 0 c) :encoding :latin-1))
                          (babel:octets-to-string
                           (subseq line (let ((v (1+ c)))
                                          (loop while (and (< v (length line))
                                                           (= (aref line v) 32))
                                                do (incf v))
                                          v))
                           :encoding :latin-1)))))

;;; ---------------------------------------------------------------------------
;;; Client
;;; ---------------------------------------------------------------------------

(defun client (&key (threads 2) (max-in-flight 16) (queue-chunks 8) (stall-ms 30000))
  (%translating (nil)
    (%call "MAKE-CLIENT" threads max-in-flight queue-chunks stall-ms)))

(defun shutdown (client &key (grace-ms 100))
  (%call "CLIENT-SHUTDOWN" client grace-ms))

(defmacro with-client ((var &rest options) &body body)
  "Shuts the client down on the way out, however you leave — which is also
what stops its runtime threads before an image dump (BOUNDARY §10)."
  `(let ((,var (client ,@options)))
     (unwind-protect (progn ,@body)
       ;; nested, so a condition from SHUTDOWN cannot skip the free and
       ;; leak the handle — the very thing this macro exists to prevent
       (unwind-protect (shutdown ,var)
         (rulisp:free ,var)))))

;;; ---------------------------------------------------------------------------
;;; Requests
;;; ---------------------------------------------------------------------------

(defvar *max-bytes* (* 256 1024 1024)
  "Default ceiling for a body buffered on the Lisp heap. An unbounded
response would otherwise exhaust the image — and in-process FFI has no
crash isolation, so that takes the host down with it. Use :SINK for bodies
larger than this; the sink path streams to a file and is uncapped.")

(defun %status-or-nil (req)
  "REQ-STATUS is 0 until the response head arrives; the condition's STATUS
slot spells 'no status yet' NIL rather than leaking that sentinel."
  (let ((s (%call "REQ-STATUS" req)))
    (and (plusp s) s)))

(defun %signal-if-failed (req url)
  "Signal the task's terminal error if it has one. REQ-READ can only report
an error it happens to be waiting inside when the task settles; both drain
loops can exit on REQ-DONE without re-entering it — most obviously in sink
mode, which never buffers a chunk — so the settled state must be consulted
explicitly. Without this a failed download reports success."
  (let ((kind (%call "REQ-ERROR-KIND" req)))
    (when kind
      (error 'http-error :kind kind
                         :detail (or (%call "REQ-ERROR-MESSAGE" req) "")
                         :status (%status-or-nil req)
                         :url url))))

(defun %drain (req url &key sink)
  "Pull the body to completion. Returns octets, or NIL when SINK was used.
The loop terminates on REQ-DONE, which the substrate guarantees is reached
on every path — completion, error, cancel, free, GC, shutdown."
  (if sink
      (progn
        (loop until (%call "REQ-DONE" req)
              do (%translating (url (%status-or-nil req))
                   (%call "REQ-READ" req 0 100)))
        nil)
      (let ((parts '()) (total 0))
        (loop for chunk = (%translating (url (%status-or-nil req))
                            (%call "REQ-READ" req 1048576 100))
              while (or chunk (not (%call "REQ-DONE" req)))
              when chunk
                do (push chunk parts) (incf total (length chunk)))
        (let ((out (make-array total :element-type '(unsigned-byte 8)))
              (at 0))
          (dolist (p (nreverse parts) out)
            (replace out p :start1 at)
            (incf at (length p)))))))

(defun request (client method url
                &key headers body sink (timeout-ms 30000)
                     (max-bytes (if sink 0 *max-bytes*))
                     (expect-success t))
  "Perform one request to completion. Returns (values body status headers),
where BODY is octets (or NIL with :SINK) and HEADERS is an alist in wire
order. Signals HTTP-ERROR on transport failures and, unless
:EXPECT-SUCCESS is NIL, on non-2xx responses; a RETRY-REQUEST restart is
established around the whole exchange.

:MAX-BYTES caps the body, enforced against bytes RECEIVED (not against a
Content-Length a hostile peer can omit); 0 means unlimited. It defaults to
*MAX-BYTES* for a buffered body and to unlimited with :SINK, because the
sink path never touches the Lisp heap."
  (loop
    (restart-case
        (let ((req (%translating (url)
                     (%call "MAKE-REQ" client (string method) url
                            (%encode-headers headers) body sink
                            timeout-ms max-bytes))))
          (unwind-protect
               (let ((data (%drain req url :sink sink)))
                 ;; Consult the settled state before the status is trusted:
                 ;; a terminal error must not be reported as "server
                 ;; returned 0", and on the sink path REQ-READ may never
                 ;; have been inside the failure at all.
                 (%signal-if-failed req url)
                 (let ((status (%call "REQ-STATUS" req))
                       (hdrs (%decode-headers (%call "REQ-HEADERS" req))))
                   (when (and expect-success (not (<= 200 status 299)))
                     (error 'http-error :kind "status"
                                        :detail (format nil "server returned ~D" status)
                                        :status status :url url))
                   (return (values data status hdrs))))
            (rulisp:free req)))
      (retry-request ()
        :report "Send the request again."
        nil))))

(defun get (client url &rest args &key &allow-other-keys)
  (apply #'request client "GET" url args))

(defun download (client url path &rest args &key &allow-other-keys)
  "Stream straight to PATH: the body never touches the Lisp heap."
  (apply #'request client "GET" url :sink (namestring path) args))

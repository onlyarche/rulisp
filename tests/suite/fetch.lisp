;;; examples/fetch suite: the async HTTPS client, exercised against the
;;; crate's own hermetic loopback server (no network, no CI flakiness).
;;;
;;; Every test states what a failure would mean, because the failure modes
;;; here are livelocks and wedged images, not wrong return values.

(in-package #:rulisp/test)

(def-suite* :rulisp-fetch)

(defvar *fetch-crate* nil)
(defvar *fetch-client* nil)
(defvar *base* nil)

(defun fetch-fn (name)
  (or (find-symbol name "FETCH") (error "FETCH:~A missing" name)))

(defun fc (name &rest args) (apply (fetch-fn name) args))

(defun ensure-fetch ()
  (unless *fetch-crate*
    (setf *fetch-crate*
          (rulisp:use-crate (asdf:system-relative-pathname
                             :rulisp "../examples/fetch/")))
    (load (asdf:system-relative-pathname :rulisp "../examples/fetch/http.lisp"))
    (setf *fetch-client* (fc "MAKE-CLIENT" 2 16 8 3000)
          *base* (fc "CLIENT-START-TEST-SERVER" *fetch-client*)))
  *fetch-client*)

(defun url (fmt &rest args) (format nil "~A~?" *base* fmt args))

(defun err-kind (e)
  (let* ((m (rulisp:rust-error-message e)) (i (position #\: m)))
    (if i (subseq m 0 i) m)))

(defmacro kind-of-signal (&body body)
  `(handler-case (progn ,@body nil)
     (rulisp:rust-error (e) (err-kind e))))

(defun slurp (req)
  "The documented pull loop."
  (let ((parts '()) (n 0))
    (loop for c = (fc "REQ-READ" req 65536 100)
          while (or c (not (fc "REQ-DONE" req)))
          when c do (push c parts) (incf n (length c)))
    (let ((out (make-array n :element-type '(unsigned-byte 8))) (at 0))
      (dolist (p (nreverse parts) out)
        (replace out p :start1 at) (incf at (length p))))))

;;; ---------------------------------------------------------------------------
;;; Contract: the shape the design promised
;;; ---------------------------------------------------------------------------

(test fetch.manifest-has-no-stored-callbacks
  "Declaring even one stored callback would force compile-file and a C
toolchain on ECL at binding-generation time. A failure here means someone
added a doorbell and the ECL-parity claim quietly died."
  (ensure-fetch)
  (let ((raw (rulisp::crate-manifest-source *fetch-crate*)))
    (is (not (search ":stored-callback" raw)))))

(test fetch.waits-are-capped
  "A Lisp thread inside a foreign call cannot be interrupted; an uncapped
wait makes the image un-Ctrl-C-able. A failure here is a ten-minute hang."
  (ensure-fetch)
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/delay/3000")
               nil nil nil 10000 0)))
    (unwind-protect
         (let ((start (get-internal-real-time)))
           (fc "REQ-WAIT" r 600000)
           (let ((ms (/ (* 1000 (- (get-internal-real-time) start))
                        internal-time-units-per-second)))
             (is (< ms 500) "req-wait 600000 took ~,0F ms" ms)))
      (fc "REQ-CANCEL" r)
      (rulisp:free r))))

(test fetch.no-thread-adoption
  "The pull design must never adopt a foreign thread into the Lisp."
  (ensure-fetch)
  (let ((before (length (bt:all-threads))))
    (dotimes (i 5)
      (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/bytes/1000")
                   nil nil nil 10000 0)))
        (slurp r)
        (rulisp:free r)))
    (is (= before (length (bt:all-threads))))))

;;; ---------------------------------------------------------------------------
;;; Data fidelity
;;; ---------------------------------------------------------------------------

(test fetch.body-and-status
  (ensure-fetch)
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/bytes/100000")
               nil nil nil 10000 0)))
    (unwind-protect
         (let ((body (slurp r)))
           (is (= 200 (fc "REQ-STATUS" r)))
           (is (= 100000 (length body)))
           (is (every (lambda (b) (= b (char-code #\x))) body))
           (is (eql 100000 (fc "REQ-TOTAL" r)))
           (is (= 100000 (fc "REQ-RECEIVED" r))))
      (rulisp:free r)))
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/status/404")
               nil nil nil 10000 0)))
    (unwind-protect (progn (slurp r) (is (= 404 (fc "REQ-STATUS" r))))
      (rulisp:free r))))

(test fetch.headers-are-lossless
  "Header values are octets, not text: obs-text must survive and duplicates
must keep their wire order. A failure means a lossy :string crept in."
  (ensure-fetch)
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/obs-text")
               nil nil nil 10000 0)))
    (unwind-protect
         (progn (slurp r)
                (is (find #xE9 (fc "REQ-HEADERS" r))
                    "the raw obs-text octet was lost"))
      (rulisp:free r)))
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/dup-headers")
               nil nil nil 10000 0)))
    (unwind-protect
         (progn
           (slurp r)
           (let* ((alist (funcall (find-symbol "%DECODE-HEADERS" "HTTP")
                                  (fc "REQ-HEADERS" r)))
                  (cookies (remove "set-cookie" alist :test-not #'equal :key #'car)))
             (is (equal '("a=1" "b=2") (mapcar #'cdr cookies)))))
      (rulisp:free r))))

(test fetch.request-headers-round-trip
  (ensure-fetch)
  (let* ((block (funcall (find-symbol "%ENCODE-HEADERS" "HTTP")
                         '(("x-one" . "1") ("x-dup" . "a") ("x-dup" . "b"))))
         (r (fc "MAKE-REQ" *fetch-client* "GET" (url "/echo-headers")
                block nil nil 10000 0)))
    (unwind-protect
         (let ((echoed (string-downcase
                        (babel:octets-to-string (slurp r) :encoding :latin-1))))
           (is (search "x-one: 1" echoed))
           (is (search "x-dup: a" echoed))
           (is (search "x-dup: b" echoed)))
      (rulisp:free r))))

;;; ---------------------------------------------------------------------------
;;; Lifecycle: the failure modes that livelock or wedge
;;; ---------------------------------------------------------------------------

(test fetch.cancel-drains-then-signals
  "Buffered bytes must be delivered before the error surfaces, and the
request must reach its terminal state. A failure is req-done stuck NIL —
the livelock two of the three candidate designs shipped."
  (ensure-fetch)
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/drip/200/20")
               nil nil nil 30000 0))
        (signalled nil))
    (unwind-protect
         (progn
           (fc "REQ-READ" r 1024 200)   ; let some bytes arrive
           (fc "REQ-CANCEL" r)
           (loop repeat 60 until (or signalled (fc "REQ-DONE" r))
                 do (handler-case (fc "REQ-READ" r 65536 50)
                      (rulisp:rust-error (e) (setf signalled (err-kind e)))))
           (is (equal "cancelled" signalled))
           (is (fc "REQ-DONE" r)))
      (rulisp:free r))))

(test fetch.terminal-state-on-every-path
  "Completion, cancel, free-mid-transfer and abandon-to-GC must all return
the admission permit and drop in-flight to 0. A failure is a permit leak:
the client wedges at max-in-flight forever."
  (ensure-fetch)
  ;; free mid-transfer
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/drip/300/20")
               nil nil nil 30000 0)))
    (fc "REQ-READ" r 1024 200)
    (rulisp:free r))
  ;; abandon without freeing: the finalizer must cancel
  (funcall (compile nil '(lambda (start client u)
                           (dotimes (i 3) (funcall start client "GET" u nil nil nil 30000 0))))
           (fetch-fn "MAKE-REQ") *fetch-client* (url "/drip/300/20"))
  (tg:gc :full t)
  (loop repeat 60 until (zerop (fc "CLIENT-IN-FLIGHT" *fetch-client*))
        do (sleep 0.05) (tg:gc :full t))
  (is (zerop (fc "CLIENT-IN-FLIGHT" *fetch-client*))
      "in-flight stuck at ~D" (fc "CLIENT-IN-FLIGHT" *fetch-client*)))

(test fetch.body-cap-on-chunked
  "The cap must be enforced against bytes received, not a Content-Length a
hostile peer can simply omit."
  (ensure-fetch)
  (let ((r (fc "MAKE-REQ" *fetch-client* "GET" (url "/no-length/2000000")
               nil nil nil 20000 100000)))
    (unwind-protect
         (progn
           (loop repeat 400 until (fc "REQ-DONE" r)
                 do (handler-case (fc "REQ-READ" r 65536 50)
                      (rulisp:rust-error () nil)))
           (is (equal "too-large" (fc "REQ-ERROR-KIND" r))))
      (rulisp:free r))))

(test fetch.sink-bypasses-the-lisp-heap
  (ensure-fetch)
  (let* ((path (merge-pathnames "rulisp-fetch-sink.bin" (uiop:temporary-directory)))
         (r (fc "MAKE-REQ" *fetch-client* "GET" (url "/bytes/1000000")
                nil nil (namestring path) 20000 0)))
    (unwind-protect
         (progn
           (loop repeat 400 until (fc "REQ-DONE" r) do (fc "REQ-READ" r 0 50))
           (is (null (fc "REQ-ERROR-KIND" r)))
           (with-open-file (s path :element-type '(unsigned-byte 8))
             (is (= 1000000 (file-length s)))))
      (rulisp:free r)
      (uiop:delete-file-if-exists path))))

(test fetch.admission-refuses-loudly
  "Silent queueing is unbounded memory; refusing must be loud and the
permit must come back."
  (ensure-fetch)
  (let* ((small (fc "MAKE-CLIENT" 1 1 4 3000))
         (base (fc "CLIENT-START-TEST-SERVER" small)))
    (unwind-protect
         (let ((a (fc "MAKE-REQ" small "GET" (format nil "~A/drip/200/20" base)
                      nil nil nil 30000 0)))
           (is (equal "busy"
                      (kind-of-signal
                        (fc "MAKE-REQ" small "GET" (format nil "~A/bytes/1" base)
                            nil nil nil 5000 0))))
           (rulisp:free a)
           (loop repeat 60 until (zerop (fc "CLIENT-IN-FLIGHT" small)) do (sleep 0.05))
           (let ((b (fc "MAKE-REQ" small "GET" (format nil "~A/bytes/10" base)
                        nil nil nil 10000 0)))
             (is (= 10 (length (slurp b))))
             (rulisp:free b)))
      (fc "CLIENT-SHUTDOWN" small 100)
      (rulisp:free small))))

(test fetch.after-shutdown-answers-immediately
  "Every export on a shut-down client must answer within milliseconds and
never hang."
  (ensure-fetch)
  (let ((c (fc "MAKE-CLIENT" 1 4 4 3000)))
    (fc "CLIENT-SHUTDOWN" c 100)
    (is (fc "CLIENT-IS-DOWN" c))
    (let ((start (get-internal-real-time)))
      (is (equal "usage"
                 (kind-of-signal
                   (fc "MAKE-REQ" c "GET" "http://127.0.0.1:9/x" nil nil nil 1000 0))))
      (is (< (/ (* 1000 (- (get-internal-real-time) start))
                internal-time-units-per-second)
             200)))
    (rulisp:free c)))

(test fetch.concurrent-lisp-threads
  "Several Lisp threads sharing one client: no data race, no lock-order
inversion between the pipe and the ready queue."
  (ensure-fetch)
  (let* ((n 4)
         (threads (loop for i below n
                        collect (bt:make-thread
                                 (lambda ()
                                   (loop repeat 5
                                         always (let ((r (fc "MAKE-REQ" *fetch-client* "GET"
                                                             (url "/bytes/5000")
                                                             nil nil nil 20000 0)))
                                                  (unwind-protect
                                                       (= 5000 (length (slurp r)))
                                                    (rulisp:free r)))))
                                 :name "fetch-load"))))
    (is (every #'identity (mapcar #'bt:join-thread threads)))
    (loop repeat 60 until (zerop (fc "CLIENT-IN-FLIGHT" *fetch-client*)) do (sleep 0.05))
    (is (zerop (fc "CLIENT-IN-FLIGHT" *fetch-client*)))))

;;; ---------------------------------------------------------------------------
;;; The veneer
;;; ---------------------------------------------------------------------------

(test fetch.veneer
  (ensure-fetch)
  (let ((client (funcall (find-symbol "CLIENT" "HTTP"))))
    (unwind-protect
         (let ((base (fc "CLIENT-START-TEST-SERVER" client)))
           (multiple-value-bind (body status headers)
               (funcall (find-symbol "GET" "HTTP") client
                        (format nil "~A/bytes/4096" base))
             (is (= 200 status))
             (is (= 4096 (length body)))
             (is (equal "4096" (cdr (assoc "content-length" headers :test #'equal)))))
           ;; non-2xx signals http-error carrying the status, with a restart
           (let ((c (handler-case
                        (progn (funcall (find-symbol "GET" "HTTP") client
                                        (format nil "~A/status/500" base))
                               nil)
                      (error (e) e))))
             (is (typep c (find-symbol "HTTP-ERROR" "HTTP")))
             (is (equal "status" (funcall (find-symbol "HTTP-ERROR-KIND" "HTTP") c)))
             (is (eql 500 (funcall (find-symbol "HTTP-ERROR-STATUS" "HTTP") c))))
           ;; :expect-success nil returns the response instead
           (is (= 500 (nth-value 1 (funcall (find-symbol "GET" "HTTP") client
                                            (format nil "~A/status/500" base)
                                            :expect-success nil)))))
      (funcall (find-symbol "SHUTDOWN" "HTTP") client)
      (rulisp:free client))))

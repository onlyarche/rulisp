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
    (load (asdf:system-relative-pathname :rulisp "../examples/fetch/http.lisp")))
  ;; the dump-hook tests legitimately shut down every client in the crate,
  ;; including this shared one — recreate it when that happened
  (when (and *fetch-client* (fc "CLIENT-IS-DOWN" *fetch-client*))
    (rulisp:free *fetch-client*)
    (setf *fetch-client* nil))
  (unless *fetch-client*
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
           ;; drain: buffered bytes come out first; the loop may also end
           ;; because REQ-DONE went true before a read observed the error
           (loop repeat 60 until (or signalled (fc "REQ-DONE" r))
                 do (handler-case (fc "REQ-READ" r 65536 50)
                      (rulisp:rust-error (e) (setf signalled (err-kind e)))))
           (is (fc "REQ-DONE" r))
           ;; the contract: once settled with an error, READ signals it —
           ;; whether or not an earlier read happened to be waiting when the
           ;; cancel landed (on CCL it never was; the test's first run there
           ;; exposed this as a race in the test, not the crate)
           (unless signalled
             (handler-case (fc "REQ-READ" r 65536 0)
               (rulisp:rust-error (e) (setf signalled (err-kind e)))))
           (is (equal "cancelled" signalled)))
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

;;; ---------------------------------------------------------------------------
;;; Regressions from the adversarial review (18 findings, all confirmed).
;;; ---------------------------------------------------------------------------

(test fetch.sink-failure-is-not-silent-success
  "The sink drain loop can exit on REQ-DONE without ever re-entering
REQ-READ, and REQ-READ was the only path an error took to Lisp. A failure
here is a download reported as successful with no file on disk."
  (ensure-fetch)
  (dotimes (i 20)
    (let ((c (handler-case
                 (progn (funcall (find-symbol "DOWNLOAD" "HTTP") *fetch-client*
                                 (url "/bytes/10000") "/no/such/dir/out.bin")
                        nil)
               (error (e) e))))
      (is (typep c (find-symbol "HTTP-ERROR" "HTTP")))
      (is (equal "io" (funcall (find-symbol "HTTP-ERROR-KIND" "HTTP") c))))))

(test fetch.transport-failure-reports-transport
  "A pre-head failure has status 0; reporting that as kind \"status\" with
status 0 defeats any handler that dispatches on kind to decide on a retry."
  (ensure-fetch)
  (let ((c (handler-case
               (progn (funcall (find-symbol "GET" "HTTP") *fetch-client*
                               "http://127.0.0.1:9/nope")
                      nil)
             (error (e) e))))
    (is (typep c (find-symbol "HTTP-ERROR" "HTTP")))
    (is (equal "transport" (funcall (find-symbol "HTTP-ERROR-KIND" "HTTP") c)))
    (is (null (funcall (find-symbol "HTTP-ERROR-STATUS" "HTTP") c)))))

(test fetch.buffered-body-is-capped-by-default
  "With no cap an unbounded response exhausts the Lisp heap — and
in-process FFI has no crash isolation, so that kills the host image."
  (ensure-fetch)
  (let ((sym (find-symbol "*MAX-BYTES*" "HTTP")))
    (is (not (null sym)))
    (progv (list sym) (list 100000)
      (is (equal "too-large"
                 (handler-case
                     (progn (funcall (find-symbol "GET" "HTTP") *fetch-client*
                                     (url "/no-length/2000000"))
                            nil)
                   (error (e) (funcall (find-symbol "HTTP-ERROR-KIND" "HTTP") e))))))))

(test fetch.header-injection-refused
  "A CRLF in a caller-supplied value would splice extra request fields
(CWE-113); once it is in the block no parser downstream can tell."
  (ensure-fetch)
  (dolist (bad '(("x-evil" . "a
inj: 1") ("bad name" . "a") ("x:y" . "a")))
    (let ((c (handler-case
                 (progn (funcall (find-symbol "GET" "HTTP") *fetch-client*
                                 (url "/echo-headers")
                                 :headers (list (cons (car bad) (cdr bad))))
                        nil)
               (error (e) e))))
      (is (typep c (find-symbol "HTTP-ERROR" "HTTP"))
          "~S was accepted" bad)))
  ;; and the Rust side refuses a malformed block outright
  (is (equal "request"
             (kind-of-signal
               (fc "MAKE-REQ" *fetch-client* "GET" (url "/echo-headers")
                   (babel:string-to-octets (format nil "x: 1~Cy: 2~C~C"
                                                   #\Newline #\Return #\Newline))
                   nil nil 5000 0)))))

(test fetch.ready-queue-is-bounded
  "Nothing in the veneer drains the ready queue, so an unbounded one grows
by one id per request for the life of the client."
  (ensure-fetch)
  (let ((c (fc "MAKE-CLIENT" 1 4 4 3000)))
    (unwind-protect
         (let ((base (fc "CLIENT-START-TEST-SERVER" c)))
           (dotimes (i 40)
             (let ((r (fc "MAKE-REQ" c "GET" (format nil "~A/bytes/16" base)
                          nil nil nil 10000 0)))
               (slurp r)
               (rulisp:free r)))
           (let ((n 0))
             (loop while (fc "CLIENT-NEXT-READY" c 0) do (incf n))
             (is (<= n 4096) "ready queue held ~D ids" n)))
      (fc "CLIENT-SHUTDOWN" c 200)
      (rulisp:free c))))

(test fetch.permit-available-when-done
  "TaskGuard must release the admission permit BEFORE publishing the
terminal state, or the documented 'wait for done, then submit' idiom races
against its own capacity check."
  (ensure-fetch)
  (let ((c (fc "MAKE-CLIENT" 1 1 4 3000)))
    (unwind-protect
         (let ((base (fc "CLIENT-START-TEST-SERVER" c)))
           (dotimes (i 25)
             (let ((r (fc "MAKE-REQ" c "GET" (format nil "~A/bytes/16" base)
                          nil nil nil 10000 0)))
               (slurp r)
               (loop repeat 300 until (fc "REQ-DONE" r) do (sleep 0.001))
               (rulisp:free r))
             (let ((refused (kind-of-signal
                              (let ((r2 (fc "MAKE-REQ" c "GET"
                                            (format nil "~A/bytes/16" base)
                                            nil nil nil 10000 0)))
                                (slurp r2)
                                (rulisp:free r2)))))
               (is (null refused) "submit after done was refused with ~A" refused))))
      (fc "CLIENT-SHUTDOWN" c 200)
      (rulisp:free c))))

(test fetch.no-adoption-during-transfer
  "Sampling only before and after cannot see an adoption that happens
mid-transfer and detaches when the OS thread exits. The count is relative
to the host's resting thread count — CCL runs an initial thread plus the
listener, so an absolute 1 was an SBCL assumption (first finding of the
fetch suite's first run on CCL)."
  (ensure-fetch)
  (let* ((baseline (length (bt:all-threads)))
         (r (fc "MAKE-REQ" *fetch-client* "GET" (url "/drip/60/10")
                nil nil nil 20000 0))
         (peak baseline))
    (unwind-protect
         (progn
           (loop repeat 40 until (fc "REQ-DONE" r)
                 do (fc "REQ-READ" r 65536 20)
                    (setf peak (max peak (length (bt:all-threads)))))
           (is (= baseline peak)
               "~D Lisp threads existed mid-transfer (baseline ~D)" peak baseline))
      (fc "REQ-CANCEL" r)
      (rulisp:free r))))

;;; ---------------------------------------------------------------------------
;;; §10: the declared dump hook (v0.4). These are the two tests the v0.3
;;; risk table promised and never shipped.
;;; ---------------------------------------------------------------------------

(defun os-thread-count ()
  "OS-level threads of this process (tokio workers are invisible to
bt:all-threads). NIL where /proc is unavailable."
  (ignore-errors
    (with-open-file (s "/proc/self/status" :if-does-not-exist nil)
      (when s
        (loop for line = (read-line s nil)
              while line
              when (and (> (length line) 8) (string= "Threads:" line :end2 8))
                return (parse-integer line :start 8 :junk-allowed t))))))

(test fetch.dump-hook-quiesces
  "With requests in flight, the crate's declared :on-dump hook must stop
every tokio thread and leave every client refusing — no foreign thread may
survive into a dumped image half-alive."
  (ensure-fetch)
  (let ((baseline (os-thread-count))
        (r (fc "MAKE-REQ" *fetch-client* "GET" (url "/drip/300/20")
               nil nil nil 30000 0)))
    (fc "REQ-READ" r 1024 200)          ; the transfer is genuinely live
    ;; what uiop:dump-image will run, invoked directly
    (rulisp::%run-crate-dump-hooks)
    (is (fc "CLIENT-IS-DOWN" *fetch-client*))
    (is (equal "usage"
               (kind-of-signal
                 (fc "MAKE-REQ" *fetch-client* "GET" (url "/bytes/1")
                     nil nil nil 5000 0))))
    ;; the in-flight request reached its terminal state
    (loop repeat 60 until (fc "REQ-DONE" r)
          do (handler-case (fc "REQ-READ" r 65536 50)
               (rulisp:rust-error () nil)))
    (is (fc "REQ-DONE" r))
    (rulisp:free r)
    ;; tokio's workers are OS threads, not Lisp threads: count them
    (let ((now (os-thread-count)))
      (if (and baseline now)
          (progn
            (loop repeat 100 while (> (or (os-thread-count) 0) baseline)
                  do (sleep 0.05))
            (is (<= (or (os-thread-count) 0) baseline)
                "~D OS threads survived the dump hook (baseline ~D)"
                (os-thread-count) baseline))
          (pass "no /proc on this host; thread-count assertion skipped")))))

(test fetch.dump-restore-refuses
  "The flagship end-to-end: dump an image with a tokio-owning client LIVE —
the declared hook quiesces it during uiop:dump-image — then restore and
assert the pre-dump client refuses with rulisp's typed condition while a
fresh client works."
  #-(or sbcl ccl)
  (pass "skipped: no uiop:dump-image on this host (ECL ships via program-op)")
  #+(or sbcl ccl)
  (let* ((tmp (uiop:temporary-directory))
         ;; per-process names — see m7: side-by-side suites must not clobber
         ;; a running executable
         (exe (merge-pathnames (format nil "rulisp-fetch-restore-test-~A"
                                       rulisp::*process-tag*) tmp))
         (script (merge-pathnames (format nil "rulisp-fetch-dump-phase-~A.lisp"
                                          rulisp::*process-tag*) tmp))
         (lisp-dir (asdf:system-relative-pathname :rulisp ""))
         (fetch-dir (asdf:system-relative-pathname :rulisp "../examples/fetch/")))
    (uiop:delete-file-if-exists exe)
    (with-open-file (out script :direction :output :if-exists :supersede)
      (format out "~
(require :asdf)
#-quicklisp
(let ((q (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname))))
  (when (probe-file q) (load q)))
(push ~S asdf:*central-registry*)
(ql:quickload '(:cffi :babel :trivial-garbage :bordeaux-threads) :silent t)
(asdf:load-system :rulisp)
(rulisp:use-crate ~S)
(defvar *c* (funcall (find-symbol \"MAKE-CLIENT\" \"FETCH\") 2 8 8 3000))
;; a request is IN FLIGHT while the image dumps; only the declared hook
;; stands between this tokio runtime and a corrupt dump
(defvar *base* (funcall (find-symbol \"CLIENT-START-TEST-SERVER\" \"FETCH\") *c*))
(defvar *r* (funcall (find-symbol \"MAKE-REQ\" \"FETCH\") *c* \"GET\"
                     (format nil \"~~A/drip/500/20\" *base*) nil nil nil 60000 0))
(funcall (find-symbol \"REQ-READ\" \"FETCH\") *r* 1024 200)
(setf uiop:*image-entry-point*
      (lambda ()
        (handler-case
            (progn
              ;; the pre-dump client is a dead-session handle now
              (handler-case
                  (progn (funcall (find-symbol \"CLIENT-IN-FLIGHT\" \"FETCH\") *c*)
                         (format t \"FAIL: pre-dump client did not signal~~%\")
                         (uiop:quit 1))
                (rulisp:stale-handle-error () t))
              (assert (eq t (rulisp:free *c*)))
              ;; and the crate works from scratch in the restored image
              (let* ((c2 (funcall (find-symbol \"MAKE-CLIENT\" \"FETCH\") 1 4 4 3000))
                     (b2 (funcall (find-symbol \"CLIENT-START-TEST-SERVER\" \"FETCH\") c2))
                     (r2 (funcall (find-symbol \"MAKE-REQ\" \"FETCH\") c2 \"GET\"
                                  (format nil \"~~A/bytes/64\" b2) nil nil nil 10000 0))
                     (got 0))
                (loop for chunk = (funcall (find-symbol \"REQ-READ\" \"FETCH\") r2 65536 100)
                      while (or chunk (not (funcall (find-symbol \"REQ-DONE\" \"FETCH\") r2)))
                      when chunk do (incf got (length chunk)))
                (assert (= 64 got))
                (rulisp:free r2)
                (funcall (find-symbol \"CLIENT-SHUTDOWN\" \"FETCH\") c2 100)
                (rulisp:free c2))
              (format t \"FETCH-RESTORE-OK~~%\")
              (uiop:quit 0))
          (error (e)
            (format t \"FAIL: ~~A~~%\" e)
            (uiop:quit 1)))))
(uiop:dump-image ~S :executable t)~%"
              (namestring lisp-dir) (namestring fetch-dir) (namestring exe)))
    (multiple-value-bind (out err code)
        (uiop:run-program
         (append #+sbcl (list "sbcl" "--non-interactive")
                 #+ccl (list (first ccl:*command-line-argument-list*) "--batch")
                 (list "--load" (uiop:native-namestring script)))
         :output :string :error-output :string
         :ignore-error-status t)
      (declare (ignore out))
      (is (zerop code) "dump phase failed:~%~A" err))
    (multiple-value-bind (out err code)
        (uiop:run-program (list (uiop:native-namestring exe))
                          :output :string :error-output :string
                          :ignore-error-status t)
      (is (zerop code) "restore phase failed: out=~A err=~A" out err)
      (is (search "FETCH-RESTORE-OK" out)))
    ;; a dumped executable is tens of MB; per-process names mean nothing
    ;; overwrites it, so remove it (and the script) here
    (uiop:delete-file-if-exists exe)
    (uiop:delete-file-if-exists script)))

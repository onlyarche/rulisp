;;; examples/httpd suite: the HTTP server whose handlers are a Lisp pull
;;; loop, exercised against 127.0.0.1 only (no network, no CI flakiness).
;;;
;;; Every test states what a failure would mean, because the failure modes
;;; here are hangs, wedged images and clients left waiting, not wrong
;;; return values. Reuses fetch.lisp's helpers (`err-kind`,
;;; `kind-of-signal`, `os-thread-count`); the system loads it first.

(in-package #:rulisp/test)

(def-suite* :rulisp-httpd)

(defvar *httpd-crate* nil)

(defun httpd-fn (name)
  (or (find-symbol name "HTTPD") (error "HTTPD:~A missing" name)))

(defun hc (name &rest args) (apply (httpd-fn name) args))

(defun ensure-httpd ()
  "Lazy on purpose: `make dist-dryrun` loads this file with cargo
unreachable, so nothing builds at load time."
  (unless *httpd-crate*
    (setf *httpd-crate*
          (rulisp:use-crate (asdf:system-relative-pathname
                             :rulisp "../examples/httpd/"))))
  *httpd-crate*)

(defun ms-since (start)
  (/ (* 1000 (- (get-internal-real-time) start))
     internal-time-units-per-second))

(defmacro with-httpd-server ((var &key (queue 8) (workers 1) (body-cap 65536))
                             &body body)
  "A server on a free loopback port, torn down in the documented order:
stop, poll stopped, shutdown, free."
  `(let ((,var (hc "MAKE-SERVER" "127.0.0.1:0" ,queue ,workers ,body-cap)))
     (unwind-protect (progn ,@body)
       (hc "SERVER-STOP" ,var)
       (loop repeat 50 until (hc "SERVER-STOPPED" ,var 100))
       (hc "SERVER-SHUTDOWN" ,var 2000)
       (rulisp:free ,var))))

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
wait makes the image un-Ctrl-C-able. A failure here is a ten-minute hang."
  (ensure-httpd)
  (with-httpd-server (s)
    (is (plusp (hc "SERVER-PORT" s)))
    (let ((start (get-internal-real-time)))
      (hc "SERVER-WAIT" s 600000)
      (let ((ms (ms-since start)))
        (is (< ms 500) "server-wait 600000 on an idle server took ~,0F ms" ms)))
    (let ((start (get-internal-real-time)))
      (is (not (hc "SERVER-STOPPED" s 600000)))
      (let ((ms (ms-since start)))
        (is (< ms 500) "server-stopped 600000 on a live server took ~,0F ms" ms)))))

(test httpd.idle-wait-is-nil-not-a-condition
  "The serve loop's idle path is a NIL, not a handler-case: `server-wait`
answers NIL on an idle tick and T when something is parked; `take-request`
on an empty queue is the typed kind \"empty\" (racing pullers), and both
report \"usage\" once the server is stopped — never a hang, never a host
condition."
  (ensure-httpd)
  (let ((s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 65536)))
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
        (os-before (os-thread-count))
        (s (hc "MAKE-SERVER" "127.0.0.1:0" 8 1 65536)))
    (unwind-protect
         (progn
           (dotimes (i 100) (hc "SERVER-WAIT" s 1))
           (is (= lisp-before (length (bt:all-threads))))
           (when os-before
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

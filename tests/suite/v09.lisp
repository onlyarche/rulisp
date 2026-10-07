;;; v0.9 suite: rulisp::Inbox, the queue direction of the boundary as a
;;; library type. tests/inbox-fixture's Ticker produces numbered events on a
;;; Rust thread of its own; Lisp pulls them through a capped wait. Nothing
;;; here needs a callback or an adopted thread, so the suite runs on every
;;; tier. (The fixture is its own crate because wordbag must stay
;;; byte-identical to the hand-written oracle.)

(in-package #:rulisp/test)

(def-suite* :rulisp-v09)

(defvar *inbox-crate* nil)

(defun ensure-inbox ()
  (or *inbox-crate*
      (setf *inbox-crate*
            (rulisp:use-crate (asdf:system-relative-pathname :rulisp "../tests/inbox-fixture/")))))

(defun ib-call (name &rest args)
  (apply (symbol-function (or (find-symbol name "INBOXFIX")
                              (error "symbol ~A not found in INBOXFIX" name)))
         args))

(defun %drain-ticker (ticker &key (wait-ms 100) (limit 2000))
  "Pull every event until the inbox reports closed; returns the events in
arrival order and the closed condition. LIMIT bounds the loop so a
regression that never closes fails instead of hanging."
  (let ((got '()))
    (loop repeat limit
          do (handler-case
                 (let ((e (ib-call "TICKER-NEXT" ticker wait-ms)))
                   (when e (push e got)))
               (rulisp:rust-error (c)
                 (return-from %drain-ticker (values (nreverse got) c)))))
    (values (nreverse got) nil)))

(test v09.inbox-delivers-in-order-then-closed
  "Every event the producer sent arrives once, in order, and then the
export signals \"closed\" — the end of the stream is a condition the loop
can stop on, not a NIL that looks like an idle tick."
  (ensure-inbox)
  (let ((ticker (ib-call "MAKE-TICKER" 50 1 64)))
    (unwind-protect
         (multiple-value-bind (events closed) (%drain-ticker ticker)
           (is (equal (loop for i below 50 collect i) events))
           (is (typep closed 'rulisp:rust-error) "the stream never reported closed")
           (when closed
             (is (search "closed" (rulisp:rust-error-message closed))))
           (is (= 0 (ib-call "TICKER-DROPPED" ticker)))
           (is (= 0 (ib-call "TICKER-PENDING" ticker))))
      (rulisp:free ticker))))

(test v09.inbox-wait-is-capped
  "Asked to wait ten minutes, a pull with nothing to take returns NIL
within the 100 ms cap: the loop stays in Lisp, where Ctrl-C lands. A
failure here is a Lisp thread stuck in a foreign call."
  (ensure-inbox)
  ;; one event now, the next a second later
  (let ((ticker (ib-call "MAKE-TICKER" 2 1000 4)))
    (unwind-protect
         (progn
           (is (eql 0 (loop repeat 20 thereis (ib-call "TICKER-NEXT" ticker 100))))
           (let ((start (get-internal-real-time)))
             (is (null (ib-call "TICKER-NEXT" ticker 600000)))
             (let ((ms (/ (* 1000 (- (get-internal-real-time) start)) internal-time-units-per-second)))
               (is (< ms 500) "a pull asked for 600000 ms took ~,0F ms" ms))))
      (rulisp:free ticker))))

(test v09.inbox-full-is-backpressure
  "A consumer that falls behind costs the producer refusals, not memory: a
capacity-4 inbox under 200 back-to-back events holds four, the producer
counts the rest as dropped, and what arrives is still in order."
  (ensure-inbox)
  (let ((ticker (ib-call "MAKE-TICKER" 200 0 4)))
    (unwind-protect
         (progn
           (sleep 0.3)
           (is (<= (ib-call "TICKER-PENDING" ticker) 4))
           (multiple-value-bind (events closed) (%drain-ticker ticker)
             (let ((dropped (ib-call "TICKER-DROPPED" ticker)))
               (is (typep closed 'rulisp:rust-error))
               (is (plusp dropped) "nothing was dropped against a capacity of 4")
               (is (= 200 (+ dropped (length events))) "~D received + ~D dropped" (length events) dropped)
               (is (equal events (sort (copy-list events) #'<))))))
      (rulisp:free ticker))))

(test v09.inbox-adopts-no-thread
  "The producer is a Rust thread that never runs Lisp code: the Lisp's own
thread list is the same while it runs, which is what keeps the garbage
collector and the debugger away from it."
  (ensure-inbox)
  (let* ((before (length (bt:all-threads)))
         (ticker (ib-call "MAKE-TICKER" 20 5 32)))
    (unwind-protect
         (progn
           (is (eql 0 (loop repeat 20 thereis (ib-call "TICKER-NEXT" ticker 100))))
           (is (= before (length (bt:all-threads))))
           (%drain-ticker ticker)
           (is (= before (length (bt:all-threads)))))
      (rulisp:free ticker))))

(test v09.inbox-free-mid-stream
  "Freeing the handle while the producer is still sending closes the
inbox; the producer stops at its next send (within one 10 ms interval),
and a new ticker works."
  (ensure-inbox)
  ;; earlier tests' producers end within their own intervals (at most 1 s)
  (loop repeat 40 until (zerop (ib-call "PRODUCERS-LIVE")) do (sleep 0.05))
  (let ((ticker (ib-call "MAKE-TICKER" 1000 10 8)))
    (is (eql 0 (loop repeat 20 thereis (ib-call "TICKER-NEXT" ticker 100))))
    (is (= 1 (ib-call "PRODUCERS-LIVE")))
    (is (eq t (rulisp:free ticker)))
    (is (loop repeat 40 thereis (zerop (ib-call "PRODUCERS-LIVE")) do (sleep 0.05))
        "the producer was still running 2 s after its ticker was freed"))
  (let ((again (ib-call "MAKE-TICKER" 3 1 8)))
    (unwind-protect
         (is (equal '(0 1 2) (%drain-ticker again)))
      (rulisp:free again))))

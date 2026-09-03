;;; v0.5 suite: "a 1.0 candidate a stranger can verify" — the defects the
;;; conformance table cannot see, and the front doors it does not cover.

(in-package #:rulisp/test)

(def-suite* :rulisp-v05)

;;; ---------------------------------------------------------------------------
;;; BOUNDARY §4: lending a Lisp buffer to Rust for the duration of a call
;;; must not stop the world. On CCL, CFFI's with-pointer-to-vector-data is
;;; ccl:with-pointer-to-ivector, whose body runs under without-gcing — so a
;;; pinned :bytes/:vec/:string argument suspended GC for every thread for
;;; the whole export, callbacks included. Measured here: a second thread
;;; must complete garbage collections WHILE the export holds the buffer.
;;; ---------------------------------------------------------------------------

(defun %gc-stamp ()
  "Something that changes when the host completes a collection, or NIL
where this host offers no counter."
  #+sbcl sb-kernel::*gc-epoch*
  #+ccl (ccl:gccounts)
  #+ecl (nth-value 1 (si::gc-stats t))
  #-(or sbcl ccl ecl) nil)

(defun %gcs-during (thunk)
  "Run THUNK on this thread while another thread requests a collection
every 20 ms; return the number of requests, issued strictly while THUNK
ran, after which the host's GC counter had actually CHANGED (a request
that merely returns because GC is inhibited does not count), and THUNK's
value. Counting starts at the thunk, not at thread creation — a warm-up
window would otherwise let a few collections through and mask the pin."
  (let* ((start nil)
         (done nil)
         (completed 0)
         (collector (bt:make-thread
                     (lambda ()
                       (loop until start do (sleep 0.005))
                       (loop until done
                             do (let ((before (%gc-stamp)))
                                  (tg:gc)
                                  ;; EQL, not EQUAL: SBCL's epoch is a fresh
                                  ;; cons per collection with equal contents
                                  (unless (eql before (%gc-stamp))
                                    (incf completed)))
                                (sleep 0.02)))
                     :name "gc-during-pin")))
    (sleep 0.02)                        ; the collector is alive and waiting
    (setf start t)
    (let ((value (funcall thunk)))
      (setf done t)
      (bt:join-thread collector)
      (values completed value))))

(test v05.pin-does-not-stop-the-world
  "A failure here means a borrowed buffer stops every other Lisp thread's
GC for the whole call — invisible to the suite (calls take microseconds)
and to §12 (the row is a runtime-check), visible to any real workload."
  (ensure-crate)
  (if (null (%gc-stamp))
      (pass "skipped: this host exposes no GC counter to observe (SBCL/CCL/ECL do)")
      (let ((octets (make-array (* 4 1024 1024) :element-type '(unsigned-byte 8)
                                                  :initial-element 1))
            (ints (make-array 65536 :element-type '(signed-byte 64) :initial-element 3)))
        (multiple-value-bind (gcs value)
            (%gcs-during (lambda () (wb-call "SLOW-SUM" octets 600)))
          (is (= (* 4 1024 1024) value))
          (is (>= gcs 10) ":bytes borrow held for 600 ms; only ~D collections completed (unpinned: ~~30)" gcs))
        (multiple-value-bind (gcs value)
            (%gcs-during (lambda () (wb-call "SLOW-DOT" ints 600)))
          (is (= (* 3 65536) value))
          (is (>= gcs 10) ":vec borrow held for 600 ms; only ~D collections completed (unpinned: ~~30)" gcs))
        ;; control: the same collector loop with no foreign call at all
        (multiple-value-bind (gcs value)
            (%gcs-during (lambda () (sleep 0.6) :idle))
          (is (eq :idle value))
          (is (>= gcs 10) "control: the collector itself made only ~D collections" gcs)))))

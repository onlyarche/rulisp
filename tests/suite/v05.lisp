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
and to §12 (the row is a runtime-check), visible to any real workload.
The bar is RELATIVE to a control on the same host: a GitHub macOS runner
completes ~6 collections per 600 ms where this machine completes ~30, so
an absolute threshold measured GC speed, not inhibition."
  (ensure-crate)
  (if (null (%gc-stamp))
      (pass "skipped: this host exposes no GC counter to observe (SBCL/CCL/ECL do)")
      (let ((octets (make-array (* 4 1024 1024) :element-type '(unsigned-byte 8)
                                                  :initial-element 1))
            (ints (make-array 65536 :element-type '(signed-byte 64) :initial-element 3))
            (control 0))
        ;; control first: the same collector loop with no foreign call
        (multiple-value-bind (gcs value)
            (%gcs-during (lambda () (sleep 0.6) :idle))
          (is (eq :idle value))
          (setf control gcs))
        (if (< control 2)
            (pass "host completes fewer than 2 collections per 600 ms (~D); too slow to observe inhibition" control)
            (let ((floor (max 1 (floor control 3))))
              (multiple-value-bind (gcs value)
                  (%gcs-during (lambda () (wb-call "SLOW-SUM" octets 600)))
                (is (= (* 4 1024 1024) value))
                (is (>= gcs floor)
                    ":bytes borrow held for 600 ms: ~D collections completed vs ~D unpinned"
                    gcs control))
              (multiple-value-bind (gcs value)
                  (%gcs-during (lambda () (wb-call "SLOW-DOT" ints 600)))
                (is (= (* 3 65536) value))
                (is (>= gcs floor)
                    ":vec borrow held for 600 ms: ~D collections completed vs ~D unpinned"
                    gcs control)))))))

;;; ---------------------------------------------------------------------------
;;; §11 key classes: a crate built with a NEWER rulisp than the loader may
;;; declare keys the loader ignores — the loader must say so (style-warning)
;;; and load anyway; older or equal, or a pre-0.5 crate without the key,
;;; must stay silent.
;;; ---------------------------------------------------------------------------

(defun %manifest-with-rulisp-version (v)
  (format nil "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"x_rulisp_\"~
               ~@[ :rulisp-version ~S~] :functions ())" v))

(test v05.newer-rulisp-warns
  (is (rulisp::%version-major-minor rulisp::*rulisp-version*)
      "the loader's own version ~S does not parse" rulisp::*rulisp-version*)
  (signals rulisp::rulisp-version-skew
    (rulisp::parse-manifest (%manifest-with-rulisp-version "99.0.0")))
  ;; the warning is informational: parsing still succeeds and records it
  (let ((m (handler-bind ((style-warning #'muffle-warning))
             (rulisp::parse-manifest (%manifest-with-rulisp-version "99.0.0")))))
    (is (string= "99.0.0" (rulisp::manifest-rulisp-version m))))
  ;; older, equal, absent, and unparsable: silent
  (dolist (v (list "0.0.1" rulisp::*rulisp-version* nil "garbage"))
    (finishes
      (handler-bind ((style-warning (lambda (w) (fail "unexpected warning for ~S: ~A" v w))))
        (rulisp::parse-manifest (%manifest-with-rulisp-version v)))))
  ;; the example crate we just loaded was built with THIS rulisp
  (ensure-crate)
  (is (string= rulisp::*rulisp-version*
               (rulisp::manifest-rulisp-version
                (rulisp::crate-manifest rulisp/test::*crate*)))))

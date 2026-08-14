;;; M1 acceptance suite: 8 items (scalar smoke + the 7 risk categories),
;;; DESIGN.md §8 M1. Each test is self-contained; the WORDBAG package is
;;; generated at run time, so symbols are resolved dynamically via WB.

(defpackage #:rulisp/test
  (:use #:cl #:fiveam))
(in-package #:rulisp/test)

(def-suite* :rulisp-m1)

(defparameter *crate-dir*
  (asdf:system-relative-pathname :rulisp "../tests/m1-handwritten/"))

(defvar *crate* nil)

(defun ensure-crate ()
  (or *crate* (setf *crate* (rulisp:use-crate *crate-dir*))))

(defun wb (name)
  (or (find-symbol name "WORDBAG")
      (error "symbol ~A not found in WORDBAG" name)))

(defun wb-call (name &rest args)
  (apply (symbol-function (wb name)) args))

(defun live-bags () (wb-call "TEST-LIVE-WORD-BAGS"))
(defun live-allocs () (wb-call "TEST-LIVE-ALLOCATIONS"))
(defun guard-drops () (wb-call "TEST-CB-GUARD-DROPS"))

(defun make-bag (&rest words)
  (let ((bag (wb-call "MAKE-WORD-BAG")))
    (dolist (w words) (wb-call "WORD-BAG-ADD" bag w))
    bag))

;;; ---------------------------------------------------------------------------
;;; Item 0 — scalar smoke + perf sanity
;;; ---------------------------------------------------------------------------

(test m0.scalar-and-bench
  (ensure-crate)
  (is (= 7 (wb-call "ADD" 3 4)))
  (is (= -1 (wb-call "ADD" 2 -3)))
  (let* ((f (symbol-function (wb "ADD")))
         (n 200000)
         (start (get-internal-real-time)))
    (dotimes (i n) (funcall f 1 2))
    (let* ((elapsed (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second))
           (ns-per-call (/ (* elapsed 1d9) n)))
      (format t "~&;; add: ~,0F ns/call (~D calls)~%" ns-per-call n)
      (is (< ns-per-call 20000)))))

;;; ---------------------------------------------------------------------------
;;; Item 1 — panic → rulisp:rust-panic, image survives
;;; ---------------------------------------------------------------------------

(test m1.panic
  (ensure-crate)
  (let ((c (handler-case (progn (wb-call "ALWAYS-PANIC") nil)
             (rulisp:rust-panic (e) e))))
    (is (not (null c)))
    (is (search "boom: intentional panic" (rulisp:rust-panic-message c))))
  (is (= 3 (wb-call "ADD" 1 2))))

(test m1.panic-abort-guard
  "A glue crate built with panic=abort must fail to COMPILE (compile_error!)."
  (let* ((cargo (or (uiop:getenv "RULISP_CARGO")
                    (let ((hc (merge-pathnames ".cargo/bin/cargo" (user-homedir-pathname))))
                      (if (probe-file hc) (uiop:native-namestring hc) "cargo"))))
         (target (merge-pathnames "target-abort-check/" *crate-dir*)))
    (multiple-value-bind (out err code)
        (uiop:run-program
         (list cargo "build"
               "--manifest-path" (uiop:native-namestring
                                  (merge-pathnames "Cargo.toml" *crate-dir*))
               "--target-dir" (uiop:native-namestring target)
               "--config" "profile.dev.panic=\"abort\"")
         :output :string :error-output :string :ignore-error-status t)
      (declare (ignore out))
      (is (not (zerop code)))
      (is (search "rulisp requires panic" err)))))

;;; ---------------------------------------------------------------------------
;;; Item 2 — Result::Err → rulisp:rust-error with rust-type
;;; ---------------------------------------------------------------------------

(test m2.fallible
  (ensure-crate)
  (is (= 42 (wb-call "PARSE-NUMBER" "42")))
  (is (= -7 (wb-call "PARSE-NUMBER" "  -7  ")))
  (let ((c (handler-case (progn (wb-call "PARSE-NUMBER" "42x") nil)
             (rulisp:rust-error (e) e))))
    (is (not (null c)))
    (is (string= "ParseError" (rulisp:rust-error-type c)))
    (is (string= "invalid digit found in string: \"42x\""
                 (rulisp:rust-error-message c)))))

;;; ---------------------------------------------------------------------------
;;; Item 3 — (ptr,len) UTF-8 both directions + dealloc pairing
;;; ---------------------------------------------------------------------------

(test m3.strings
  (ensure-crate)
  (is (string= "Hello, World!" (wb-call "GREET" "World")))
  (is (string= "Hello, 리스퍼!" (wb-call "GREET" "리스퍼")))
  (is (string= "" (wb-call "ECHO" "")))
  (let ((s "한글과 🦀 crab, ünïcödé"))
    (is (string= s (wb-call "ECHO" s)))))

(test m3.string-allocations
  (ensure-crate)
  (let ((before (live-allocs)))
    (dotimes (i 100)
      (wb-call "GREET" "abc")
      (wb-call "ECHO" "")
      (wb-call "ECHO" "μ"))
    (is (= before (live-allocs)))))

;;; ---------------------------------------------------------------------------
;;; Item 4 — handle lifecycle: idempotent free, UAF signals, GC finalization,
;;;          free vs in-flight call
;;; ---------------------------------------------------------------------------

(test m4.handle-lifecycle
  (ensure-crate)
  (let ((bag (make-bag "one" "two")))
    (is (= 2 (wb-call "WORD-BAG-LEN" bag)))
    (is (typep bag 'rulisp:handle))
    (is (typep bag (wb "WORD-BAG")))
    (signals rulisp:rust-error (wb-call "WORD-BAG-ADD" bag ""))
    (is (eq t (rulisp:free bag)))
    (is (eq nil (rulisp:free bag)))
    (signals rulisp:freed-handle-error (wb-call "WORD-BAG-LEN" bag))
    (is (= 3 (wb-call "ADD" 1 2)))))

(test m4.gc-finalization
  (ensure-crate)
  (let ((before (live-bags)))
    (funcall (compile nil '(lambda (ctor n)
                             (dotimes (i n) (funcall ctor))))
             (symbol-function (wb "MAKE-WORD-BAG")) 1000)
    (is (= (+ before 1000) (live-bags)))
    ;; SBCL reaches exactly zero; hosts with conservative stack scanning
    ;; (e.g. CCL) may pin a straggler in a dead frame — allow a tiny residue
    (let ((slack #+sbcl 0 #-sbcl 2))
      (loop repeat 100
            until (<= (live-bags) (+ before slack))
            do (tg:gc :full t) (sleep 0.05))
      (is (<= (live-bags) (+ before slack))))))

(test m4.free-vs-in-flight
  (ensure-crate)
  (let* ((bag (make-bag "w"))
         (before (live-bags))
         (thread (bt:make-thread
                  (lambda () (wb-call "WORD-BAG-SLOW-LEN" bag 600))
                  :name "rulisp-slow-len")))
    (sleep 0.2)                       ; thread is inside the foreign call
    (is (eq t (rulisp:free bag)))     ; free is accepted (deferred)
    (is (= before (live-bags)))       ; but the Rust object is NOT dropped yet
    (is (= 1 (bt:join-thread thread))); in-flight call completed normally
    (is (= (1- before) (live-bags)))  ; dropped when the last call exited
    (is (eq nil (rulisp:free bag)))))

(test m4.concurrent-load
  "Concurrent load-crate calls on the same crate must serialize on the
registry lock and all land on the same crate object (review finding: the
registries were unsynchronized)."
  (ensure-crate)
  (let* ((artifact (rulisp::crate-source-path *crate*))
         (threads (loop repeat 4
                        collect (bt:make-thread
                                 (lambda ()
                                   (rulisp:load-crate artifact :crate "wordbag"))
                                 :name "rulisp-concurrent-load"))))
    (is (every (lambda (c) (eq c *crate*)) (mapcar #'bt:join-thread threads)))))

;;; ---------------------------------------------------------------------------
;;; Item 5 — callbacks: iteration, condition identity + Rust Drop on unwind,
;;;          reentrancy, callback freeing its own receiver
;;; ---------------------------------------------------------------------------

(test m5.callback-basic
  (ensure-crate)
  (let ((bag (make-bag "a" "b" "c"))
        (seen '()))
    (is (= 3 (wb-call "FOR-EACH-WORD" bag (lambda (w) (push w seen)))))
    (is (equal '("a" "b" "c") (nreverse seen)))
    (rulisp:free bag)))

(test m5.callback-condition-identity
  (ensure-crate)
  (let* ((bag (make-bag "a" "b"))
         (c (make-condition 'simple-error :format-control "callback boom"))
         (drops-before (guard-drops))
         (caught (handler-case
                     (progn
                       (wb-call "FOR-EACH-WORD" bag
                                (lambda (w) (declare (ignore w)) (error c)))
                       nil)
                   (error (e) e))))
    (is (eq c caught))                        ; the SAME condition object
    (is (= (1+ drops-before) (guard-drops)))  ; Rust destructor ran on early return
    (rulisp:free bag)))

(test m5.callback-reentrant
  (ensure-crate)
  (let ((bag (make-bag "x" "y" "z"))
        (lens '()))
    (is (= 3 (wb-call "FOR-EACH-WORD" bag
                      (lambda (w)
                        (declare (ignore w))
                        (push (wb-call "WORD-BAG-LEN" bag) lens)))))
    (is (equal '(3 3 3) lens))
    (rulisp:free bag)))

(test m5.callback-frees-receiver
  (ensure-crate)
  (let* ((bag (make-bag "only"))
         (before (live-bags))
         (free-result nil))
    (is (= 1 (wb-call "FOR-EACH-WORD" bag
                      (lambda (w)
                        (declare (ignore w))
                        (setf free-result (rulisp:free bag))))))
    (is (eq t free-result))            ; accepted, deferred past the outer call
    (is (= (1- before) (live-bags)))   ; dropped once the outer call returned
    (signals rulisp:freed-handle-error (wb-call "WORD-BAG-LEN" bag))))

;;; ---------------------------------------------------------------------------
;;; Item 6 — live reload: new behavior, stale handles refuse but still free
;;; ---------------------------------------------------------------------------

(test m6.reload
  (ensure-crate)
  (let ((bag (make-bag "w"))
        (gen-before (rulisp:crate-generation *crate*)))
    (is (string= "Hello, W!" (wb-call "GREET" "W")))
    (rulisp:use-crate *crate-dir* :features '("alt-greeting"))
    (is (= (1+ gen-before) (rulisp:crate-generation *crate*)))
    (is (string= "Hi, W!" (wb-call "GREET" "W")))
    (signals rulisp:stale-handle-error (wb-call "WORD-BAG-LEN" bag))
    (is (eq t (rulisp:free bag)))      ; freed via the birth generation's shim
    ;; restore the default build so later tests see default behavior
    (rulisp:use-crate *crate-dir*)
    (is (string= "Hello, W!" (wb-call "GREET" "W")))))

(test m6.captured-wrapper-gate
  "A wrapper closure captured before a reload keeps its birth generation's
fn-ptr; the gate must therefore compare cell generation against the WRAPPER's
birth generation (review finding: gating against the crate's current
generation let a stale wrapper dereference a new generation's handle — UB)."
  (ensure-crate)
  (let ((old-len (symbol-function (wb "WORD-BAG-LEN")))
        (old-bag (make-bag "a")))
    (rulisp:use-crate *crate-dir*)          ; generation+1, same build
    (let ((new-bag (make-bag "b" "c")))
      ;; captured old wrapper + NEW handle: refused (this was the UB path)
      (signals rulisp:stale-handle-error (funcall old-len new-bag))
      ;; captured old wrapper + OLD handle: coherent generation pair, still
      ;; sound (the old mapping is kept alive) — runs
      (is (= 1 (funcall old-len old-bag)))
      ;; current wrapper + old handle: stale
      (signals rulisp:stale-handle-error (wb-call "WORD-BAG-LEN" old-bag))
      ;; a generation-stale handle prints as stale
      (is (search "stale" (format nil "~A" old-bag)))
      (is (eq t (rulisp:free old-bag)))
      (is (eq t (rulisp:free new-bag))))))

;;; ---------------------------------------------------------------------------
;;; Item 7 — save-lisp-and-die round trip (subprocess orchestration)
;;; ---------------------------------------------------------------------------

(test m7.dump-restore
  ;; Dumps an executable image in a subprocess and re-launches it, via
  ;; uiop:dump-image — save-lisp-and-die on SBCL, ccl:save-application on
  ;; CCL (whose toplevel is fixed to uiop's restore-image, so the
  ;; post-restore assertions live in *image-entry-point*, which runs after
  ;; the restore hooks — i.e. after %restore-all-crates has bumped the
  ;; session and reloaded the crate).
  #-(or sbcl ccl)
  (pass "skipped: no uiop:dump-image on this host — ECL has none; ECL executables ship via asdf:program-op (docs/design/v04-plan.md item 4)")
  #+(or sbcl ccl)
  (let* ((tmp (uiop:temporary-directory))
         (exe (merge-pathnames "rulisp-m1-restore-test" tmp))
         (script (merge-pathnames "rulisp-m1-dump-phase.lisp" tmp))
         (lisp-dir (asdf:system-relative-pathname :rulisp "")))
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
(defvar *bag* nil)
(rulisp:use-crate ~S)
(setf *bag* (funcall (find-symbol \"MAKE-WORD-BAG\" \"WORDBAG\")))
(funcall (find-symbol \"WORD-BAG-ADD\" \"WORDBAG\") *bag* \"pre-dump\")
;; abandoned after restore: its finalizer must fire in the restored image
;; and must NOT make a foreign call (the mapping it remembers is gone)
(defvar *abandoned* (funcall (find-symbol \"MAKE-WORD-BAG\" \"WORDBAG\")))
(defvar *saved-greet* (symbol-function (find-symbol \"GREET\" \"WORDBAG\")))
(setf uiop:*image-entry-point*
      (lambda ()
        (handler-case
            (progn
              (assert (string= \"Hello, restored!\"
                               (funcall (find-symbol \"GREET\" \"WORDBAG\") \"restored\")))
              (handler-case
                  (progn (funcall (find-symbol \"WORD-BAG-LEN\" \"WORDBAG\") *bag*)
                         (format t \"FAIL: pre-dump handle did not signal~~%\")
                         (uiop:quit 1))
                (rulisp:stale-handle-error () t))
              (assert (eq t (rulisp:free *bag*)))   ; dead session: freed w/o foreign call
              (assert (eq nil (rulisp:free *bag*)))
              (handler-case
                  (progn (funcall *saved-greet* \"x\")
                         (format t \"FAIL: saved closure did not signal~~%\")
                         (uiop:quit 1))
                (rulisp:crate-not-loaded-error () t))
              ;; the finalizer path: drop the pre-dump handle NOW, in the
              ;; restored image, and force collection — the session gate
              ;; must turn the finalizer into a no-op instead of a foreign
              ;; call into an unmapped library
              (setf *abandoned* nil)
              (trivial-garbage:gc :full t)
              (let ((bag2 (funcall (find-symbol \"MAKE-WORD-BAG\" \"WORDBAG\"))))
                (funcall (find-symbol \"WORD-BAG-ADD\" \"WORDBAG\") bag2 \"post\")
                (assert (= 1 (funcall (find-symbol \"WORD-BAG-LEN\" \"WORDBAG\") bag2))))
              (format t \"RESTORE-OK~~%\")
              (uiop:quit 0))
          (error (e)
            (format t \"FAIL: ~~A~~%\" e)
            (uiop:quit 1)))))
(uiop:dump-image ~S :executable t)~%"
              (namestring lisp-dir) (namestring *crate-dir*) (namestring exe)))
    (multiple-value-bind (out err code)
        (uiop:run-program
         (append #+sbcl (list "sbcl" "--non-interactive")
                 ;; uiop:argv0 is NIL on CCL 1.13; the raw argument list
                 ;; still carries the binary path
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
      (is (search "RESTORE-OK" out)))))

;;; v0.4 suite: BOUNDARY conformance — tests for the six normative claims
;;; that were documented but enforced by nothing (docs/design/v04-plan.md
;;; item 1). Each test names its clause.

(in-package #:rulisp/test)

(def-suite* :rulisp-v04)

;;; ---------------------------------------------------------------------------
;;; §6.3(3), first sentence: a swallowed CallbackError's stash is discarded
;;; when the shim returns OK — the caller sees a normal return.
;;; ---------------------------------------------------------------------------

(test v04.swallowed-callback-error-is-discarded
  (ensure-crate)
  (let ((bag (wb-call "MAKE-WORD-BAG")))
    (dolist (w '("alpha" "bad" "gamma"))
      (wb-call "WORD-BAG-ADD" bag w))
    ;; the callback signals on one word; count-ok swallows and keeps going
    (is (= 2 (wb-call "COUNT-OK" bag
                      (lambda (w)
                        (when (string= w "bad")
                          (error "callback rejects ~A" w))))))
    ;; and the stash really is gone: the very next boundary call is clean
    (is (= 3 (wb-call "WORD-BAG-LEN" bag)))
    (rulisp:free bag)))

;;; ---------------------------------------------------------------------------
;;; §6.3(3), second sentence: swallow-then-fail is conservatively status 4 —
;;; the ORIGINAL Lisp condition re-signals, not Rust's own error.
;;; ---------------------------------------------------------------------------

(define-condition v04-marker (error) ())

(test v04.swallow-then-fail-resignals-the-original
  (ensure-crate)
  ;; callback signals: the marker condition must come back, not rust-error
  (signals v04-marker
    (wb-call "SWALLOW-THEN-FAIL" (lambda (x) (declare (ignore x))
                                   (error 'v04-marker))))
  ;; control: callback succeeds -> Rust's own error surfaces as status 1
  (handler-case
      (progn (wb-call "SWALLOW-THEN-FAIL" (lambda (x) (declare (ignore x))))
             (fail "swallow-then-fail did not signal"))
    (rulisp:rust-error (e)
      (is (search "own error after swallow" (rulisp:rust-error-message e))))))

;;; ---------------------------------------------------------------------------
;;; §2's exception: a panic inside a *_free shim is caught and swallowed —
;;; it never crosses the boundary, via explicit free or the GC finalizer.
;;; ---------------------------------------------------------------------------

(test v04.free-shim-swallows-drop-panic
  (ensure-crate)
  ;; disarmed control: a normal drop
  (let ((dud (wb-call "MAKE-GRENADE" nil)))
    (is (eq t (rulisp:free dud))))
  ;; armed: Drop panics inside the free shim; the shim catches it
  (let ((live (wb-call "MAKE-GRENADE" t)))
    (is (eq t (rulisp:free live))))
  ;; the library is still fully usable afterwards
  (is (string= "Hello, still-alive!" (wb-call "GREET" "still-alive")))
  ;; the finalizer path drives the same free shim: abandon an armed one
  (funcall (compile nil '(lambda (ctor) (funcall ctor t)))
           (symbol-function (wb "MAKE-GRENADE")))
  (tg:gc :full t)
  (pass "armed grenade abandoned to GC; a finalizer panic would have crashed here"))

;;; ---------------------------------------------------------------------------
;;; §8: a mutex poisoned by a caught panic reports status 2 (rust-panic) on
;;; the next lock — it does not deadlock and does not succeed.
;;; ---------------------------------------------------------------------------

(test v04.poisoned-mutex-reports-panic
  (ensure-crate)
  (let ((bag (wb-call "MAKE-WORD-BAG")))
    (wb-call "WORD-BAG-ADD" bag "x")
    (signals rulisp:rust-panic (wb-call "WORD-BAG-POISON" bag))
    ;; the next use of the same mutex is also a panic (poisoned), status 2
    (handler-case
        (progn (wb-call "WORD-BAG-LEN" bag)
               (fail "poisoned mutex did not signal"))
      (rulisp:rust-panic (e)
        (is (search "poison" (string-downcase (rulisp:rust-panic-message e))))))
    ;; other handles are unaffected
    (let ((clean (wb-call "MAKE-WORD-BAG")))
      (is (= 0 (wb-call "WORD-BAG-LEN" clean)))
      (rulisp:free clean))
    (rulisp:free bag)))

;;; ---------------------------------------------------------------------------
;;; §3: last_error is thread-local per library — two threads failing
;;; concurrently in one library never see each other's message.
;;; ---------------------------------------------------------------------------

(test v04.last-error-is-thread-local
  (ensure-crate)
  (let* ((iterations 200)
         (mine (lambda (tag)
                 (lambda ()
                   (loop repeat iterations
                         always
                         (handler-case
                             (progn (wb-call "PARSE-NUMBER" tag) nil)
                           (rulisp:rust-error (e)
                             (search tag (rulisp:rust-error-message e))))))))
         (a (bt:make-thread (funcall mine "not-a-number-AAA") :name "last-error-a"))
         (b (bt:make-thread (funcall mine "not-a-number-BBB") :name "last-error-b")))
    (is (eq t (bt:join-thread a)) "thread A saw a foreign error message")
    (is (eq t (bt:join-thread b)) "thread B saw a foreign error message")))

;;; ---------------------------------------------------------------------------
;;; §2: out-params are written only on OK. Exercised at the FFI level: a
;;; sentinel in the out-param must survive an ERR return untouched.
;;; ---------------------------------------------------------------------------

(test v04.out-params-untouched-on-err
  (ensure-crate)
  (let* ((crate (gethash "wordbag" rulisp::*crates*))
         (sym (rulisp::dlsym-ptr (rulisp::crate-lib-handle crate)
                                 "wordbag_rulisp_parse_number"))
         (bad (babel:string-to-octets "definitely not a number" :encoding :utf-8)))
    (is (not (null sym)))
    (cffi:with-foreign-objects ((out :int64) (buf :uint8 (length bad)))
      (dotimes (i (length bad))
        (setf (cffi:mem-aref buf :uint8 i) (aref bad i)))
      (setf (cffi:mem-ref out :int64) #x1DEA)
      (let ((status (cffi:foreign-funcall-pointer sym ()
                                                  :pointer buf
                                                  rulisp::uintptr (length bad)
                                                  :pointer out
                                                  :int32)))
        (is (= 1 status) "expected STATUS_ERR, got ~D" status)
        (is (= #x1DEA (cffi:mem-ref out :int64))
            "out-param was written on an ERR return"))
      ;; control: the same out-param IS written on OK
      (let* ((good (babel:string-to-octets "42" :encoding :utf-8))
             (gbuf (cffi:foreign-alloc :uint8 :initial-contents (coerce good 'list))))
        (unwind-protect
             (progn
               (is (= 0 (cffi:foreign-funcall-pointer sym ()
                                                      :pointer gbuf
                                                      rulisp::uintptr (length good)
                                                      :pointer out
                                                      :int32)))
               (is (= 42 (cffi:mem-ref out :int64))))
          (cffi:foreign-free gbuf))))))

;;; ---------------------------------------------------------------------------
;;; §7 ECL: callbacks require the native compiler, and its absence must fail
;;; through the NAMED manifest-error — not a raw compile-file error. The
;;; injection is the real scenario: point ECL's C compiler at a nonexistent
;;; binary.
;;; ---------------------------------------------------------------------------

(test v04.ecl-toolchain-failure-is-named
  #-ecl (pass "skipped: exercises ECL's native-compiler guard (rulisp::%define-callback-trampoline #+ecl branch)")
  #+ecl
  (let ((c::*cc* "/nonexistent/rulisp-test-cc"))
    (handler-case
        (progn (rulisp::%define-callback-trampoline
                '(defun %v04-ecl-toolchain-probe () 'unused))
               (fail "no condition despite a broken C compiler"))
      (rulisp:manifest-error (e)
        (is (search "native compiler"
                    (rulisp::manifest-error-message e)))))))

;;; ---------------------------------------------------------------------------
;;; §11: (:option :bool) is outside the vocabulary. The macro refuses to
;;; emit it, but the LOADER must also refuse a hand-written manifest that
;;; carries it — the gap the conformance sweep found.
;;; ---------------------------------------------------------------------------

(test v04.option-bool-rejected-by-the-loader
  ;; OPTION-INNER is the single point both the param and the result
  ;; branches of the wrapper generator resolve (:option X) through
  (signals rulisp:manifest-error (rulisp::option-inner '(:option :bool)))
  (is (eq :i8 (rulisp::option-inner '(:option :i8))))
  (is (eq :string (rulisp::option-inner '(:option :string)))))

;;; ---------------------------------------------------------------------------
;;; §1/§3: each cdylib statically links its own runtime — last_error slots
;;; are PER LIBRARY, so concurrent failures in two libraries never cross.
;;; ---------------------------------------------------------------------------

(test v04.last-error-is-per-library
  (ensure-crate)
  (rulisp:use-crate (asdf:system-relative-pathname :rulisp "../examples/rx/"))
  (let* ((iterations 100)
         (wordbag-worker
           (bt:make-thread
            (lambda ()
              (loop repeat iterations
                    always (handler-case
                               (progn (wb-call "PARSE-NUMBER" "wordbag-side-input") nil)
                             (rulisp:rust-error (e)
                               (search "wordbag-side-input"
                                       (rulisp:rust-error-message e))))))
            :name "per-lib-wordbag"))
         (rx-worker
           (bt:make-thread
            (lambda ()
              (let ((make-regex (symbol-function (find-symbol "MAKE-REGEX" "RX"))))
                (loop repeat iterations
                      always (handler-case
                                 (progn (funcall make-regex "rx-side-[unclosed") nil)
                               (rulisp:rust-error (e)
                                 (search "rx-side-"
                                         (rulisp:rust-error-message e)))))))
            :name "per-lib-rx")))
    (is (eq t (bt:join-thread wordbag-worker))
        "a wordbag error message leaked from another library")
    (is (eq t (bt:join-thread rx-worker))
        "an rx error message leaked from another library")))

;;; ---------------------------------------------------------------------------
;;; §10: declared dump hooks (:on-dump). The loader must call every loaded
;;; crate's declared hook before a dump, warn-and-proceed on failure, and
;;; refuse a malformed declaration at the manifest.
;;; ---------------------------------------------------------------------------

(test v04.on-dump-declared-hook-runs
  (ensure-crate)
  (let ((before (wb-call "TEST-DUMP-PREPS")))
    (rulisp::%run-crate-dump-hooks)
    (is (= (1+ before) (wb-call "TEST-DUMP-PREPS"))
        "the loader did not call the declared hook")))

(test v04.on-dump-failing-hook-warns-and-proceeds
  "A dump must never be wedged by its own cleanup: a failing hook is a
warning, and the dump machinery keeps going."
  (ensure-crate)
  (wb-call "SET-DUMP-PREP-FAIL" t)
  (unwind-protect
       (let ((before (wb-call "TEST-DUMP-PREPS")))
         (signals warning (rulisp::%run-crate-dump-hooks))
         (is (= (1+ before) (wb-call "TEST-DUMP-PREPS"))))
    (wb-call "SET-DUMP-PREP-FAIL" nil)))

(test v04.on-dump-manifest-validation
  "The hook is called through a fixed () -> int32 signature, so a
mismatched declaration would be UB — the manifest must refuse it."
  (flet ((mf (fn-entry on-dump)
           (format nil "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" ~
                        :prefix \"x_rulisp_\" :on-dump ~S ~
                        :functions (~A))" on-dump fn-entry)))
    ;; names no declared function
    (signals rulisp:manifest-error
      (rulisp::parse-manifest
       (mf "(:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\" :params () :result :unit :error nil)"
           "nope")))
    ;; declared, but takes a parameter
    (signals rulisp:manifest-error
      (rulisp::parse-manifest
       (mf "(:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\" :params ((:name \"a\" :type :i64)) :result :unit :error nil)"
           "f")))
    ;; declared, but returns a value
    (signals rulisp:manifest-error
      (rulisp::parse-manifest
       (mf "(:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\" :params () :result :i64 :error nil)"
           "f")))
    ;; well-formed: accepted, recorded
    (is (string= "f"
                 (rulisp::manifest-on-dump
                  (rulisp::parse-manifest
                   (mf "(:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\" :params () :result :unit :error \"Error\")"
                       "f")))))))

;;; ---------------------------------------------------------------------------
;;; §9: the cache copy name must be unique ACROSS processes sharing a cache.
;;; Found by the ECL deployment verification: two instances started in the
;;; same second wrote the same copy, and copy-file rewrote a library the
;;; other process had already mapped — SEGV. Also: the sweep must not delete
;;; a fresh copy another process may still be about to dlopen.
;;; ---------------------------------------------------------------------------

(test v04.cache-copy-names-are-process-unique
  (let ((a (rulisp::%cache-copy-name "wordbag"))
        (b (rulisp::%cache-copy-name "wordbag")))
    (is (search rulisp::*process-tag* a) "name carries no process tag: ~A" a)
    (is (string/= a b) "two loads in one process got the same copy name")
    ;; a fresh tag computation (what a restored image does) is the same
    ;; process, hence the same tag; the field is still non-empty and tagged
    (is (> (length rulisp::*process-tag*) 1))
    (is (find (char rulisp::*process-tag* 0) "pr"))))

(test v04.cache-sweep-spares-other-processes-fresh-copies
  (let* ((dir (rulisp::cache-directory))
         (own-old (merge-pathnames
                   (format nil "sweeptest-~A-c1-1.so" rulisp::*process-tag*) dir))
         (foreign-fresh (merge-pathnames "sweeptest-pOTHER-c1-1.so" dir))
         (current (merge-pathnames
                   (format nil "sweeptest-~A-c2-2.so" rulisp::*process-tag*) dir)))
    (unwind-protect
         (progn
           (dolist (f (list own-old foreign-fresh current))
             (with-open-file (s f :direction :output :if-exists :supersede)
               (write-string "x" s)))
           (rulisp::%sweep-crate-cache "sweeptest" current)
           (is (null (probe-file own-old)) "own older generation not swept")
           (is (probe-file foreign-fresh)
               "another process's fresh copy was deleted — that process may not have dlopened it yet")
           (is (probe-file current) "the current copy was swept"))
      (dolist (f (list own-old foreign-fresh current))
        (ignore-errors (delete-file f))))))

;;; ---------------------------------------------------------------------------
;;; A second constructor on one handle type is expressible only with
;;; #[rulisp(constructor, name = …)] — the derived name make-<type> would
;;; collide, and duplicate lisp names are a load-time error.
;;; ---------------------------------------------------------------------------

(test v04.constructor-name-attribute
  (ensure-crate)
  (let ((plain (wb-call "MAKE-WORD-BAG"))
        (named (wb-call "MAKE-WORD-BAG-FROM" "alpha, beta,gamma,,")))
    (is (= 0 (wb-call "WORD-BAG-LEN" plain)))
    (is (= 3 (wb-call "WORD-BAG-LEN" named)))
    (is (typep named (wb "WORD-BAG")) "the named constructor returns the same handle class")
    (wb-call "WORD-BAG-ADD" named "delta")
    (is (= 4 (wb-call "WORD-BAG-LEN" named)))
    (rulisp:free plain)
    (rulisp:free named)))

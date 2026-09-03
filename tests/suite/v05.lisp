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

;;; ---------------------------------------------------------------------------
;;; The REPL front door: every generated function and handle class has a
;;; docstring; a crate's `///` arrives through the manifest's :doc key and
;;; survives the hardened reader; (describe crate) answers the first
;;; questions.
;;; ---------------------------------------------------------------------------

(test v05.docstrings-present
  (ensure-crate)
  (let* ((m (rulisp::crate-manifest rulisp/test::*crate*))
         (pkg (rulisp::crate-package rulisp/test::*crate*)))
    (dolist (f (rulisp::manifest-functions m))
      (let* ((sym (find-symbol (string-upcase (rulisp::fn-spec-lisp-name f)) pkg))
             (doc (and sym (documentation sym 'function))))
        (is (and doc (plusp (length doc))) "no docstring on ~A" sym)
        (is (search (rulisp::fn-spec-rust-name f) doc)
            "docstring of ~A does not name its Rust export" sym)))
    (dolist (h (rulisp::manifest-handles m))
      (let* ((sym (find-symbol (string-upcase (rulisp::handle-spec-lisp-name h)) pkg))
             (doc (documentation (find-class sym) t)))
        (is (and doc (search (rulisp::handle-spec-rust-name h) doc))
            "no class docstring on ~A" sym)))
    ;; the Rust `///` text of a documented export made it through
    (let ((doc (documentation (find-symbol "SLOW-SUM" pkg) 'function)))
      (is (search "borrowed byte buffer" doc)
          "slow_sum's /// comment is missing from its docstring: ~S" doc))
    (let ((doc (documentation (find-class (find-symbol "GRENADE" pkg)) t)))
      (is (search "Drop panics when armed" doc)))))

(test v05.doc-escaping
  "A :doc string with the characters that could break the manifest reader
— quotes, backslashes, a #. that would be reader-eval if it were not text
— plus a 4 KiB paragraph reads back byte for byte under the hardened reader."
  (let* ((payload (format nil "say \"hi\" and C:\\path, then #.(uiop:quit) and ~A"
                          (make-string 4096 :initial-element #\x)))
         (escaped (with-output-to-string (o)
                    (loop for c across payload
                          do (case c
                               (#\\ (write-string "\\\\" o))
                               (#\" (write-string "\\\"" o))
                               (t (write-char c o))))))
         (m (rulisp::parse-manifest
             (format nil "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"x_rulisp_\"
                          :handles ((:handle :rust-name \"H\" :lisp-name \"h\" :free \"h_free\" :doc \"~A\"))
                          :functions ((:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\"
                                       :params () :result :unit :error nil :doc \"~A\")))"
                     escaped escaped))))
    (is (string= payload (rulisp::fn-spec-doc (first (rulisp::manifest-functions m)))))
    (is (string= payload (rulisp::handle-spec-doc (first (rulisp::manifest-handles m)))))))

(test v05.describe-crate
  (ensure-crate)
  (let ((text (with-output-to-string (s) (describe rulisp/test::*crate* s))))
    (dolist (needle '("rulisp crate" "Built with" "make-word-bag" "Dump hook" "word-bag"))
      (is (search needle text) "describe output lacks ~S" needle))))

;;; ---------------------------------------------------------------------------
;;; v0.5 item 9: the :string ASCII fast path. Both directions take a typed
;;; loop while the text is ASCII and hand the same bytes to babel at the
;;; first char/byte >= 128 — so that is the seam, and these are the strings
;;; that sit on it. Identity through wordbag's echo (Lisp -> Rust -> Lisp),
;;; plus the two helpers themselves, so the fast path cannot be bypassed
;;; silently and cannot accept what it must refuse.
;;; ---------------------------------------------------------------------------

(test v05.utf8-fastpath-boundary
  (ensure-crate)
  (let ((cases
          (list ""
                "plain ascii"
                (make-string 65536 :initial-element #\a)
                (format nil "~Cnon-ascii first" (code-char 233))
                (format nil "non-ascii last~C" (code-char 233))
                (coerce (loop for c from 128 to 255 collect (code-char c)) 'string)
                (format nil "a~Cb" (code-char 127))         ; DEL: the last ASCII code
                (format nil "a~Cb" (code-char 128))         ; the first non-ASCII code
                (format nil "nul~Cinside" (code-char 0))    ; interior NUL stays legal
                (format nil "~C~C" (code-char #x1F600) (code-char #x10FFFF)) ; 4-byte
                (concatenate 'string (make-string 65535 :initial-element #\a)
                             (string (code-char #x1F600)))  ; ASCII until the last char
                (make-array 8 :element-type 'character :fill-pointer 5
                              :initial-contents "abcdefgh") ; non-simple
                (coerce "base" 'simple-base-string))))
    (dolist (s cases)
      (let ((back (wb-call "ECHO" s)))
        (is (string= s back) "echo changed ~S" (subseq s 0 (min 16 (length s))))
        (is (= (length s) (length back))))))
  ;; the helpers: ASCII goes through, the first code/byte >= 128 refuses
  (is (equalp (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(104 105))
              (rulisp::%ascii-octets "hi")))
  (is (null (rulisp::%ascii-octets (string (code-char 128)))))
  (is (null (rulisp::%ascii-octets (format nil "ok until~C" (code-char 233)))))
  (is (null (rulisp::%ascii-octets 42)))
  (is (string= "hi" (rulisp::%octets-to-ascii-string
                     (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(104 105)))))
  (is (null (rulisp::%octets-to-ascii-string
             (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(104 195 169))))))

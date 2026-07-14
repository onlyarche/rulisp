;;; M2 fixture suite (DESIGN.md §8 M2): manifest validation — corruption and
;;; version mismatch signal NAMED conditions, half-generation is banned,
;;; :target checking, use-value restart, golden manifest snapshot.

(in-package #:rulisp/test)

(def-suite* :rulisp-m2)

(defun parse (s) (rulisp::parse-manifest s))

(defun string-replace-once (needle replacement s)
  (let ((i (search needle s)))
    (assert i () "fixture needle ~S not found" needle)
    (concatenate 'string
                 (subseq s 0 i) replacement (subseq s (+ i (length needle))))))

;;; ---------------------------------------------------------------------------
;;; Manifest reader fixtures: every corruption → rulisp:manifest-error
;;; ---------------------------------------------------------------------------

(test fx.not-a-manifest
  (signals rulisp:manifest-error (parse "(:not-a-manifest)"))
  (signals rulisp:manifest-error (parse "42"))
  (signals rulisp:manifest-error (parse "")))

(test fx.read-eval-blocked
  "#. must be rejected by the hardened reader, never evaluated."
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema #.(+ 1 0) :abi 1 :crate \"x\" :prefix \"x_rulisp_\")")))

(test fx.unknown-symbols-rejected
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 1 :abi banana :crate \"x\" :prefix \"x_rulisp_\")")))

(test fx.newer-schema-refused
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 2 :abi 1 :crate \"x\" :prefix \"x_rulisp_\")")))

(test fx.missing-required-keys
  ;; no :prefix
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\")"))
  ;; no :crate
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 1 :abi 1 :prefix \"p\")")))

(test fx.bad-errors-list
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"p\" :errors (1 2))")))

(test fx.bad-param-form
  (signals rulisp:manifest-error
    (parse "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"p\"
             :functions ((:fn :rust-name \"f\" :lisp-name \"f\" :symbol \"f\"
                          :params ((:type :i64)) :result :unit :error nil)))")))

(test fx.unknown-keys-ignored
  "Unknown plist keys must be ignored — additive manifest evolution is free."
  (let ((m (parse "(:rulisp-manifest :schema 1 :abi 1 :crate \"x\" :prefix \"p\"
                    :future-extension (:whatever 42))")))
    (is (string= "x" (rulisp::manifest-crate m)))))

(test fx.callback-result-must-be-unit
  (signals rulisp:manifest-error
    (rulisp::ensure-trampoline '(:callback :params (:string) :result :i64))))

;;; ---------------------------------------------------------------------------
;;; :target check
;;; ---------------------------------------------------------------------------

(test fx.target-check
  ;; unknown tokens pass (refuse only positively identified mismatches)
  (is (nth-value 0 (rulisp::target-compatible-p "quantum-unknown-os9")))
  #+(and x86-64 linux)
  (progn
    (is (nth-value 0 (rulisp::target-compatible-p "x86_64-unknown-linux-gnu")))
    (is (not (nth-value 0 (rulisp::target-compatible-p "aarch64-apple-darwin"))))
    (is (not (nth-value 0 (rulisp::target-compatible-p "x86_64-pc-windows-msvc"))))))

;;; ---------------------------------------------------------------------------
;;; use-value restart on generated wrappers
;;; ---------------------------------------------------------------------------

(test fx.use-value-restart
  (ensure-crate)
  (is (= 99 (handler-bind ((rulisp:rust-error (lambda (c) (use-value 99 c))))
              (wb-call "PARSE-NUMBER" "42x"))))
  (is (eq :fallback
          (handler-bind ((rulisp:rust-panic (lambda (c) (use-value :fallback c))))
            (wb-call "ALWAYS-PANIC")))))

;;; ---------------------------------------------------------------------------
;;; Half-generation ban: a bad manifest must not touch the existing API
;;; ---------------------------------------------------------------------------

(test fx.partial-generation-ban
  (ensure-crate)
  (let* ((crate rulisp/test::*crate*)
         (raw (rulisp::crate-manifest-source crate))
         ;; corrupt ONE fn's result type to something outside the closed v1
         ;; vocabulary; the parse succeeds, PREPARE must fail before commit
         (bad-raw (string-replace-once ":result :i64 :error \"ParseError\""
                                       ":result :quux :error \"ParseError\""
                                       raw))
         (bad-manifest (parse bad-raw))
         (gen-before (rulisp:crate-generation crate)))
    (signals rulisp:manifest-error
      (rulisp::%commit-generation crate
                                  (rulisp::crate-source-path crate)
                                  (rulisp::crate-lib-handle crate)
                                  bad-manifest
                                  bad-raw
                                  (rulisp::crate-cache-path crate)))
    ;; nothing was committed: same generation, API fully intact
    (is (= gen-before (rulisp:crate-generation crate)))
    (is (string= raw (rulisp::crate-manifest-source crate)))
    (is (string= "Hello, X!" (wb-call "GREET" "X")))
    (is (= 42 (wb-call "PARSE-NUMBER" "42")))))

;;; ---------------------------------------------------------------------------
;;; Golden snapshot: the embedded manifest is byte-identical to tests/golden/
;;; (the M3 proc-macro must reproduce exactly this)
;;; ---------------------------------------------------------------------------

(test fx.golden-manifest
  (ensure-crate)
  (let ((golden (asdf:system-relative-pathname
                 :rulisp "../tests/golden/wordbag.manifest.sexp")))
    (is (string= (uiop:read-file-string golden)
                 (rulisp::crate-manifest-source rulisp/test::*crate*)))))

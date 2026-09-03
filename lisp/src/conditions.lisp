(in-package #:rulisp)

(define-condition rulisp-error (error) ())

(define-condition rust-error (rulisp-error)
  ((message :initarg :message :initform "" :reader rust-error-message)
   (rust-type :initarg :rust-type :initform nil :reader rust-error-type)
   (function-name :initarg :function-name :initform nil :reader rust-error-function-name))
  (:report (lambda (c s)
             (format s "Rust error~@[ ~A~]~@[ in ~A~]: ~A"
                     (rust-error-type c) (rust-error-function-name c)
                     (rust-error-message c)))))

(define-condition rust-panic (rulisp-error)
  ((message :initarg :message :initform "" :reader rust-panic-message)
   (function-name :initarg :function-name :initform nil :reader rust-panic-function-name))
  (:report (lambda (c s)
             (format s "Rust panic~@[ in ~A~]: ~A"
                     (rust-panic-function-name c) (rust-panic-message c)))))

(define-condition invalid-argument (rulisp-error)
  ((message :initarg :message :initform "" :reader invalid-argument-message)
   (function-name :initarg :function-name :initform nil :reader invalid-argument-function-name))
  (:report (lambda (c s)
             (format s "Invalid argument~@[ in ~A~]: ~A"
                     (invalid-argument-function-name c) (invalid-argument-message c)))))

(define-condition invalid-handle-error (rulisp-error)
  ((function-name :initarg :function-name :initform nil
                  :reader invalid-handle-function-name)))

(define-condition freed-handle-error (invalid-handle-error) ()
  (:report (lambda (c s)
             (format s "Handle already freed~@[ (in ~A)~]"
                     (invalid-handle-function-name c)))))

(define-condition stale-handle-error (invalid-handle-error)
  ((handle-generation :initarg :handle-generation :initform nil
                      :reader stale-handle-generation)
   (crate-generation :initarg :crate-generation :initform nil
                     :reader stale-crate-generation))
  (:report (lambda (c s)
             (format s "Stale handle~@[ (in ~A)~]: handle gen ~A, crate gen ~A"
                     (invalid-handle-function-name c)
                     (stale-handle-generation c) (stale-crate-generation c)))))

(define-condition crate-not-loaded-error (rulisp-error)
  ((name :initarg :name :initform nil :reader crate-not-loaded-name)
   (message :initarg :message :initform "" :reader crate-not-loaded-message))
  (:report (lambda (c s)
             (format s "Crate ~A is not loaded~@[: ~A~]"
                     (crate-not-loaded-name c)
                     (let ((m (crate-not-loaded-message c)))
                       (and (plusp (length m)) m))))))

(define-condition build-error (rulisp-error)
  ((command :initarg :command :initform nil :reader build-error-command)
   (stderr :initarg :stderr :initform "" :reader build-error-stderr))
  (:report (lambda (c s)
             (format s "cargo build failed~@[ (~A)~]:~%~A"
                     (build-error-command c) (build-error-stderr c)))))

(define-condition manifest-error (rulisp-error)
  ((message :initarg :message :initform "" :reader manifest-error-message))
  (:report (lambda (c s)
             (format s "Manifest error: ~A" (manifest-error-message c)))))

(define-condition abi-mismatch-error (rulisp-error)
  ((expected :initarg :expected :initform nil :reader abi-mismatch-expected)
   (actual :initarg :actual :initform nil :reader abi-mismatch-actual)
   (message :initarg :message :initform nil :reader abi-mismatch-message))
  (:report (lambda (c s)
             (format s "ABI mismatch: ~@[~A; ~]expected ~A, got ~A"
                     (abi-mismatch-message c)
                     (abi-mismatch-expected c) (abi-mismatch-actual c)))))


(define-condition rulisp-version-skew (style-warning)
  ((crate :initarg :crate :reader rulisp-version-skew-crate)
   (built-with :initarg :built-with :reader rulisp-version-skew-built-with)
   (loader :initarg :loader :reader rulisp-version-skew-loader))
  (:report (lambda (c s)
             (format s "crate ~A was built with rulisp ~A but this loader is ~A: ~
                        manifest keys it relies on may be ignored here ~
                        (docs/stability.md §7)"
                     (rulisp-version-skew-crate c)
                     (rulisp-version-skew-built-with c)
                     (rulisp-version-skew-loader c))))
  (:documentation "Signaled (as a style-warning) when a crate's manifest
declares a newer rulisp major.minor than the loader's. Informational: an
older loader still loads the crate; only enhancement keys it does not know
are ignored, and a load-bearing key would have raised :schema instead."))
